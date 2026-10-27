import AVFoundation

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264, hevc, prores422
    var id: Self { self }
    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .prores422: "ProRes 422"
        }
    }
}

/// Writes video frames and Grabby audio into a QuickTime movie. All writer
/// access happens on a private serial queue.
final class MovieRecorder: @unchecked Sendable {
    let url: URL
    let norm: VideoNorm

    private let queue = DispatchQueue(label: "grabby.recorder")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastVideoTime: CMTime = .zero
    private var finished = false

    init(url: URL, codec: VideoCodec, norm: VideoNorm, withAudio: Bool) throws {
        self.url = url
        self.norm = norm
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoWidthKey: 720,
            AVVideoHeightKey: norm.height,
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: norm.pixelAspect.h,
                AVVideoPixelAspectRatioVerticalSpacingKey: norm.pixelAspect.v,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: norm == .pal ? AVVideoColorPrimaries_EBU_3213 : AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ],
        ]
        switch codec {
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: norm.frameRate,
            ]
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoExpectedSourceFrameRateKey: norm.frameRate,
            ]
        case .prores422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        }

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw RecorderError.setupFailed }
        writer.add(videoInput)

        if withAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }
        guard writer.startWriting() else { throw writer.error ?? RecorderError.setupFailed }
    }

    /// Seconds of video written so far.
    var duration: TimeInterval {
        queue.sync {
            guard let startTime else { return 0 }
            return max(0, (lastVideoTime - startTime).seconds)
        }
    }

    func append(_ frame: VideoFrame) {
        queue.async { [self] in
            guard !finished, writer.status == .writing, frame.norm == norm else { return }
            if startTime == nil {
                writer.startSession(atSourceTime: frame.time)
                startTime = frame.time
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            if adaptor.append(frame.pixelBuffer, withPresentationTime: frame.time) {
                lastVideoTime = frame.time
            }
        }
    }

    /// Audio must already be on the host clock, like the video timestamps.
    func append(audio sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !finished, writer.status == .writing, let startTime, let audioInput,
                  CMSampleBufferGetPresentationTimeStamp(sample) >= startTime,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sample)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                finished = true
                guard startTime != nil, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(throwing: writer.error ?? RecorderError.noFrames)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.endSession(atSourceTime: lastVideoTime)
                writer.finishWriting { [writer, url] in
                    if writer.status == .completed {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: writer.error ?? RecorderError.setupFailed)
                    }
                }
            }
        }
    }
}

enum RecorderError: LocalizedError {
    case setupFailed, noFrames
    var errorDescription: String? {
        switch self {
        case .setupFailed: "The movie file could not be created."
        case .noFrames: "No video was received, so nothing was recorded."
        }
    }
}
