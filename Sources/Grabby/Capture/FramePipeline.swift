import AVFoundation
import CGrabby
import CoreVideo
import os

enum Deinterlace: String, CaseIterable, Identifiable, Codable {
    case off, blend, bob
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "Off"
        case .blend: "Blend"
        case .bob: "Line doubling"
        }
    }
    var cValue: grabby_deinterlace_t {
        switch self {
        case .off: GRABBY_DEINTERLACE_NONE
        case .blend: GRABBY_DEINTERLACE_BLEND
        case .bob: GRABBY_DEINTERLACE_BOB
        }
    }
}

struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
    let norm: VideoNorm
}

/// Turns driver frames into tagged `CVPixelBuffer`s and fans them out to the
/// preview layer, the active recorder and the still-photo slot. Runs on the
/// driver's USB thread.
final class FramePipeline: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    private struct State {
        var deinterlace: Deinterlace = .blend
        var norm: VideoNorm = .pal
        var recorder: MovieRecorder?
        var latest: VideoFrame?
        var frameTimes: [UInt64] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    init() {
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = CGColor.black
    }

    var deinterlace: Deinterlace {
        get { state.withLock { $0.deinterlace } }
        set { state.withLock { $0.deinterlace = newValue } }
    }

    var norm: VideoNorm {
        get { state.withLock { $0.norm } }
        set { state.withLock { $0.norm = newValue } }
    }

    var recorder: MovieRecorder? {
        get { state.withLock { $0.recorder } }
        set { state.withLock { $0.recorder = newValue } }
    }

    var latestFrame: VideoFrame? { state.withLock { $0.latest } }

    /// Frames per second over the last two seconds.
    var frameRate: Double {
        state.withLock { s in
            guard let first = s.frameTimes.first, let last = s.frameTimes.last,
                  s.frameTimes.count > 1, last > first else { return 0 }
            return Double(s.frameTimes.count - 1) / (Double(last - first) / 1e9)
        }
    }

    func reset() {
        state.withLock {
            $0.latest = nil
            $0.frameTimes.removeAll()
        }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func handle(_ raw: RawFrame) {
        let (mode, norm, recorder) = state.withLock { ($0.deinterlace, $0.norm, $0.recorder) }
        guard let buffer = makePixelBuffer(raw, mode: mode, norm: norm) else { return }
        let time = CMTime(value: CMTimeValue(raw.hostTimeNanos), timescale: 1_000_000_000)
        let frame = VideoFrame(pixelBuffer: buffer, time: time, norm: norm)

        state.withLock { s in
            s.latest = frame
            s.frameTimes.append(raw.hostTimeNanos)
            let cutoff = raw.hostTimeNanos &- 2_000_000_000
            s.frameTimes.removeAll { $0 < cutoff }
        }
        display(frame)
        recorder?.append(frame)
    }

    private func makePixelBuffer(_ raw: RawFrame, mode: Deinterlace, norm: VideoNorm) -> CVPixelBuffer? {
        if pool == nil || poolSize != (raw.width, raw.height) {
            pool = Self.makePool(width: raw.width, height: raw.height, norm: norm)
            poolSize = (raw.width, raw.height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let dst = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        grabby_copy_frame(raw.bytes, Int32(raw.stride), dst, Int32(CVPixelBufferGetBytesPerRow(buffer)),
                          Int32(raw.width), Int32(raw.height), mode.cValue)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        if mode == .off {
            // Tell encoders and players the picture still holds two fields.
            CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferFieldDetailKey,
                                  kCVImageBufferFieldDetailSpatialFirstLineEarly, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferFieldCountKey)
            CVBufferRemoveAttachment(buffer, kCVImageBufferFieldDetailKey)
        }
        return buffer
    }

    private static func makePool(width: Int, height: Int, norm: VideoNorm) -> CVPixelBufferPool? {
        let attachments: [CFString: Any] = [
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            kCVImageBufferColorPrimariesKey: norm == .pal
                ? kCVImageBufferColorPrimaries_EBU_3213 : kCVImageBufferColorPrimaries_SMPTE_C,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferPixelAspectRatioKey: [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: norm.pixelAspect.h,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: norm.pixelAspect.v,
            ],
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8_yuvs,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVBufferPropagatedAttachmentsKey: attachments,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func display(_ frame: VideoFrame) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(array) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
