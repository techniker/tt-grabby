import AVFoundation

/// Captures the Grabby's USB audio interface (handled by CoreAudio), feeds
/// the recorder and optionally plays the sound through the Mac's output.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let monitorOutput = AVCaptureAudioPreviewOutput()
    private let queue = DispatchQueue(label: "grabby.audio")
    private var input: AVCaptureDeviceInput?

    /// Receives every audio buffer, retimed to the host clock.
    var onSample: (@Sendable (CMSampleBuffer) -> Void)?

    var isRunning: Bool { session.isRunning && input != nil }

    static func findDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                         mediaType: .audio, position: .unspecified)
        return discovery.devices.first {
            $0.localizedName.localizedCaseInsensitiveContains("grabby")
                || $0.manufacturer.localizedCaseInsensitiveContains("terratec")
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    override init() {
        super.init()
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        monitorOutput.volume = 0
        session.beginConfiguration()
        if session.canAddOutput(dataOutput) { session.addOutput(dataOutput) }
        if session.canAddOutput(monitorOutput) { session.addOutput(monitorOutput) }
        session.commitConfiguration()
    }

    /// Attaches the Grabby audio device if present and starts the session.
    /// `completion` reports whether audio is available; it runs on the audio queue.
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if input == nil, let device = Self.findDevice(),
               let newInput = try? AVCaptureDeviceInput(device: device) {
                session.beginConfiguration()
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    input = newInput
                }
                session.commitConfiguration()
            }
            if input != nil, !session.isRunning { session.startRunning() }
            completion(input != nil)
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            if let input { session.removeInput(input) }
            input = nil
        }
    }

    var monitorVolume: Float {
        get { monitorOutput.volume }
        set { monitorOutput.volume = newValue }
    }

    /// Average level of the loudest channel in dBFS, or nil without audio.
    var level: Float? {
        guard isRunning, let channels = dataOutput.connection(with: .audio)?.audioChannels,
              !channels.isEmpty else { return nil }
        return channels.map(\.averagePowerLevel).max()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let onSample else { return }
        // Video is stamped with host time, so bring audio onto the same clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostPTS = CMSyncConvertTime(pts, from: session.synchronizationClock ?? CMClockGetHostTimeClock(),
                                        to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: hostPTS, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if let retimed { onSample(retimed) }
    }
}
