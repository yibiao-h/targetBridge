import XCTest
import CoreVideo
import CoreGraphics
import ScreenCaptureKit
@testable import TargetBridge

final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testLowLatencyPrioritizesSmoothVideoWithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .smooth1440p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertNil(settings.audioEnabled)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertEqual(settings.audioEnabled, true)
    }

    func testAudioPreferenceRepairRestoresOnlyTheAmbiguousDisabledState() {
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: true))
        XCTAssertFalse(TBDisplaySenderService.restoredAudioEnabled(from: false, repairPending: false))
        XCTAssertTrue(TBDisplaySenderService.restoredAudioEnabled(from: true, repairPending: false))
    }
}

final class TBDPCMTransportTests: XCTestCase {
    func testNegotiationDoesNotSendNewPacketsToOldReceivers() {
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: true), .dpcm10Bit)
        for support: Bool? in [nil, false] {
            XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: support,
                                                   supportsRawNV12: true, rawOverride: false), .rawNV12)
            XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: true, supportsDPCM: support,
                                                   supportsRawNV12: support, rawOverride: true), .encoded)
        }
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: false, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: false), .encoded)
        XCTAssertEqual(TBVideoTransport.resolve(wantsDPCM: false, supportsDPCM: true,
                                               supportsRawNV12: true, rawOverride: true), .rawNV12)
    }

    func testCodecLabelsDescribeTheNegotiatedTransport() {
        XCTAssertEqual(TBVideoTransport.dpcm10Bit.codecName(encoded: "HEVC"), "DPCM RGB 10-bit")
        XCTAssertEqual(TBVideoTransport.rawNV12.codecName(encoded: "HEVC"), "NV12 RAW 8-bit")
        XCTAssertEqual(TBVideoTransport.encoded.codecName(encoded: "H.264"), "H.264")
    }

    func testNegotiatedTransportConfiguresActualCaptureDepthAndColorSpace() {
        let configuration = SCStreamConfiguration()
        TBVideoTransport.dpcm10Bit.configureCapture(configuration)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(configuration.colorSpaceName, CGColorSpace.displayP3)
        for transport in [TBVideoTransport.rawNV12, .encoded] {
            let legacy = SCStreamConfiguration()
            transport.configureCapture(legacy)
            XCTAssertEqual(legacy.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    private func buffer(format: OSType, width: Int = 1024, height: Int = 3) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testCPUFallbackPreservesAllTenBitsFromCapturedBuffer() throws {
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for channel in 0..<3 {
            let row = base.advanced(by: channel * stride).assumingMemoryBound(to: UInt32.self)
            for level in 0..<1024 { row[level] = (3 << 30) | (UInt32(level) << (channel * 10)) }
        }
        let original = Data(bytes: base, count: stride * 3)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let encoder = TBDPCMFrameEncoder(useGPU: false)
        let payload = try XCTUnwrap(encoder.encode(pixelBuffer))
        var info = tb_dpcm_info()
        var decoded = Data(count: stride * 3)
        payload.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self).baseAddress
            XCTAssertEqual(tb_dpcm_parse(input, payload.count, &info), 0)
            XCTAssertEqual(info.ten_bit, 1)
            XCTAssertEqual(info.width, 1024)
            XCTAssertEqual(info.height, 3)
            decoded.withUnsafeMutableBytes { output in
                XCTAssertEqual(tb_dpcm_decode(input, payload.count,
                    output.bindMemory(to: UInt8.self).baseAddress, Int32(stride)), 0)
            }
        }
        for channel in 0..<3 {
            let row = channel * stride..<(channel * stride + 4096)
            XCTAssertEqual(decoded.subdata(in: row), original.subdata(in: row))
        }
    }

    func testDPCMRejectsNV12AndEightBitRGBInsteadOfReinterpretingMemory() throws {
        let encoder = TBDPCMFrameEncoder(useGPU: false)
        let invalidBuffers = [
            try buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 64),
            try buffer(format: kCVPixelFormatType_32BGRA),
            try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked, width: 5121)
        ]
        for pixelBuffer in invalidBuffers {
            XCTAssertNil(encoder.encode(pixelBuffer))
            XCTAssertNil(encoder.encodePacket(pixelBuffer))
        }
    }

    func testCPUOwnedPacketsRetainTenBitPixelsAcrossEncoderReuseAndDestruction() throws {
        try assertOwnedPacketsSurviveReuse(useGPU: false)
    }

    func testGPUOwnedPacketsRetainTenBitPixelsAcrossEncoderReuseAndDestruction() throws {
        guard let probe = tb_dpcm_gpu_create() else {
            throw XCTSkip("Metal DPCM encoder unavailable")
        }
        tb_dpcm_gpu_destroy(probe)
        try assertOwnedPacketsSurviveReuse(useGPU: true)
    }

    private func assertOwnedPacketsSurviveReuse(useGPU: Bool) throws {
        let width = 1024, height = 3
        let pixelBuffer = try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked,
                                     width: width, height: height)
        var encoder: TBDPCMFrameEncoder? = TBDPCMFrameEncoder(useGPU: useGPU)
        var retained: [(packet: Data, pixels: Data)] = []
        for frame in 0..<8 {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            var pixels = Data(capacity: width * height * 4)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width {
                    let blue = UInt32((x + frame) & 1023)
                    let green = UInt32((1023 - x + frame + y) & 1023)
                    let red = UInt32((x * 5 + frame + y) & 1023)
                    row[x] = (3 << 30) | (red << 20) | (green << 10) | blue
                }
                pixels.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            retained.append((try XCTUnwrap(encoder?.encodePacket(pixelBuffer)), pixels))
            for snapshot in retained {
                try assertPacket(snapshot.packet, decodesTo: snapshot.pixels, width: width, height: height)
            }
        }
        encoder = nil
        for snapshot in retained {
            try assertPacket(snapshot.packet, decodesTo: snapshot.pixels, width: width, height: height)
        }
    }

    private func assertPacket(_ packet: Data, decodesTo pixels: Data, width: Int, height: Int) throws {
        XCTAssertEqual(Int(TBMonitorProtocol.readBE32(packet, offset: 0)), packet.count - 4)
        var wire = packet
        let (type, payload) = try XCTUnwrap(try TBMonitorProtocol.drainPacket(from: &wire))
        XCTAssertEqual(type, .rawDPCM)
        XCTAssertTrue(wire.isEmpty)
        XCTAssertEqual(packet, TBMonitorProtocol.makePacket(type: .rawDPCM, payload: payload))
        var info = tb_dpcm_info()
        var decoded = Data(count: width * height * 4)
        payload.withUnsafeBytes { input in
            let base = input.bindMemory(to: UInt8.self).baseAddress
            XCTAssertEqual(tb_dpcm_parse(base, payload.count, &info), 0)
            XCTAssertEqual(info.ten_bit, 1)
            XCTAssertEqual(info.width, Int32(width))
            XCTAssertEqual(info.height, Int32(height))
            decoded.withUnsafeMutableBytes { output in
                XCTAssertEqual(tb_dpcm_decode(base, payload.count,
                    output.bindMemory(to: UInt8.self).baseAddress, Int32(width * 4)), 0)
            }
        }
        XCTAssertEqual(decoded, pixels)
    }
}

final class TBVirtualDisplayModeSelectionTests: XCTestCase {
    private typealias Candidate = TBVirtualDisplayModeSelection.Candidate
    private let standard = Candidate(pointWidth: 2240, pointHeight: 1260,
                                     pixelWidth: 2240, pixelHeight: 1260, refreshRate: 60)
    private let retina = Candidate(pointWidth: 2240, pointHeight: 1260,
                                   pixelWidth: 4480, pixelHeight: 2520, refreshRate: 60)
    private let requested = TBVirtualDisplayModeSize(width: 2240, height: 1260)

    func testSameLogicalSizeSelectsHiDPIRegardlessOfEnumerationOrder() {
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard, retina], mode: requested, refreshRate: 60), 1)
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [retina, standard], mode: requested, refreshRate: 60), 0)
    }

    func testHiDPIModeMustBeAvailableBeforeStartupCanSelectIt() {
        // The standard variant can appear before WindowServer publishes HiDPI.
        // It must not end the startup retry loop with the wrong backing size.
        XCTAssertNil(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard], mode: requested, refreshRate: 60))
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [standard, retina], mode: requested, refreshRate: 60), 1)
    }

    func testNative1080pStillSelectsOneToOnePixels() {
        let native = Candidate(pointWidth: 1920, pointHeight: 1080,
                               pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        let doubled = Candidate(pointWidth: 1920, pointHeight: 1080,
                                pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let mode = TBVirtualDisplayModeSize(width: 1920, height: 1080, isHiDPI: false)
        XCTAssertEqual(TBVirtualDisplayModeSelection.preferredIndex(
            in: [doubled, native], mode: mode, refreshRate: 60), 1)
        XCTAssertNil(TBVirtualDisplayModeSelection.preferredIndex(
            in: [doubled], mode: mode, refreshRate: 60))
    }

    func testSavedChoicePreservesBothHiDPIAndExplicitStandardModes() throws {
        for (index, choice) in [standard, retina].enumerated() {
            let restored = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(choice))
            XCTAssertEqual(TBVirtualDisplayModeSelection.savedIndex(
                in: [standard, retina], choice: restored), index)
        }
        XCTAssertNil(TBVirtualDisplayModeSelection.savedIndex(in: [standard], choice: retina))
    }

    func testModeSwitchSuccessRequiresMatchingBackingReadback() {
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { self.standard }))
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { nil }))
        XCTAssertTrue(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { true }, readBack: { self.retina }))
        XCTAssertFalse(TBVirtualDisplayModeSelection.applyAndVerify(retina,
            apply: { false }, readBack: { XCTFail("failed switch must not be published"); return self.retina }))
    }
}

/// The production startup wrapper is exercised with a suspended asynchronous
/// start. No SCStream, display, network, or system permissions are involved.
final class TBCaptureStartupTests: XCTestCase {
    @MainActor
    private final class DeferredStart {
        var beginCount = 0
        private var continuation: CheckedContinuation<Void, Error>?
        private var started: CheckedContinuation<Void, Never>?

        func begin() async throws {
            beginCount += 1
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ error: Error? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    @MainActor
    func testCurrentStartupCanPublishWithoutDiscarding() async throws {
        let gate = DeferredStart()
        var discarded = 0
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { true },
                                            begin: { try await gate.begin() },
                                            discard: { discarded += 1 })
        }
        await gate.waitUntilStarted()
        gate.finish()
        let canPublish = try await task.value
        XCTAssertTrue(canPublish)
        XCTAssertEqual(gate.beginCount, 1)
        XCTAssertEqual(discarded, 0)
    }

    @MainActor
    func testStopDuringStartupDiscardsLateStreamBeforePublication() async throws {
        let gate = DeferredStart()
        var current = true
        var discarded = 0
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { current },
                                            begin: { try await gate.begin() },
                                            discard: { discarded += 1 })
        }
        await gate.waitUntilStarted()
        current = false // stop/reconnect while the original SCStream is starting
        gate.finish()
        let canPublish = try await task.value
        XCTAssertFalse(canPublish)
        XCTAssertEqual(discarded, 1)
    }

    @MainActor
    func testSupersededAttemptDoesNotEvenStart() async throws {
        let gate = DeferredStart()
        var discarded = 0
        let canPublish = try await TBCaptureStartup.start(isCurrent: { false },
                                                         begin: { try await gate.begin() },
                                                         discard: { discarded += 1 })
        XCTAssertFalse(canPublish)
        XCTAssertEqual(gate.beginCount, 0)
        XCTAssertEqual(discarded, 1)
    }

    @MainActor
    func testStartupFailureDiscardsOnlyItsOwnResources() async {
        enum Failure: Error { case capture }
        let gate = DeferredStart()
        var oldDiscarded = 0
        var replacementIsActive = false
        let task = Task {
            try await TBCaptureStartup.start(isCurrent: { !replacementIsActive },
                                            begin: { try await gate.begin() },
                                            discard: { oldDiscarded += 1 })
        }
        await gate.waitUntilStarted()
        replacementIsActive = true
        gate.finish(Failure.capture)
        do {
            _ = try await task.value
            XCTFail("capture failure must be propagated")
        } catch Failure.capture {
            // The session caller checks its generation before reporting/stopping.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(oldDiscarded, 1)
        XCTAssertTrue(replacementIsActive)
    }
}
