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
        XCTAssertNil(encoder.encode(try buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 64, height: 64)))
        XCTAssertNil(encoder.encode(try buffer(format: kCVPixelFormatType_32BGRA)))
        XCTAssertNil(encoder.encode(try buffer(format: kCVPixelFormatType_ARGB2101010LEPacked, width: 5121)))
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
