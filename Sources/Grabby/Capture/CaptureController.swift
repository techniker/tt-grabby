import AppKit
import Observation

enum NormMode: String, CaseIterable, Identifiable, Codable {
    case auto, pal, ntsc
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .pal: "PAL"
        case .ntsc: "NTSC"
        }
    }
    var forced: VideoNorm? {
        switch self {
        case .auto: nil
        case .pal: .pal
        case .ntsc: .ntsc
        }
    }
}

enum ConnectionState: Equatable {
    case searching
    case connected
    case failed(String)
}

@MainActor
@Observable
final class CaptureController {
    let pipeline = FramePipeline()
    @ObservationIgnored private lazy var device = DeviceSession(pipeline: pipeline)
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var audioPermitted = false

    private(set) var connection: ConnectionState = .searching
    private(set) var signal: SignalStatus?
    private(set) var activeNorm: VideoNorm = .pal
    private(set) var frameRate: Double = 0
    private(set) var audioAvailable = false
    private(set) var audioLevel: Float?
    private(set) var isRecording = false
    private(set) var isFinishingRecording = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastSavedURL: URL?
    private(set) var flashCount = 0
    var errorMessage: String?

    var input: VideoInput { didSet { save(input, "input"); applyInput() } }
    var normMode: NormMode { didSet { save(normMode, "normMode"); applyNormMode() } }
    var deinterlace: Deinterlace { didSet { save(deinterlace, "deinterlace"); pipeline.deinterlace = deinterlace } }
    var codec: VideoCodec { didSet { save(codec, "codec") } }
    var photoFormat: PhotoFormat { didSet { save(photoFormat, "photoFormat") } }
    var monitorAudio: Bool { didSet { defaults.set(monitorAudio, forKey: "monitorAudio"); applyMonitor() } }
    var monitorVolume: Double { didSet { defaults.set(monitorVolume, forKey: "monitorVolume"); applyMonitor() } }
    private(set) var controls: [PictureControl: Int]

    init() {
        func load<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        input = load("input", VideoInput.composite)
        normMode = load("normMode", NormMode.auto)
        deinterlace = load("deinterlace", Deinterlace.blend)
        codec = load("codec", VideoCodec.h264)
        photoFormat = load("photoFormat", PhotoFormat.png)
        monitorAudio = defaults.bool(forKey: "monitorAudio")
        monitorVolume = defaults.object(forKey: "monitorVolume") as? Double ?? 0.8
        let saved = defaults.dictionary(forKey: "controls") as? [String: Int] ?? [:]
        controls = Dictionary(uniqueKeysWithValues: PictureControl.allCases.map {
            ($0, saved[$0.title] ?? $0.defaultValue)
        })
        pipeline.deinterlace = deinterlace
        audio.onSample = { [pipeline] sample in pipeline.recorder?.append(audio: sample) }
    }

    // MARK: - Lifecycle

    func activate() {
        guard timer == nil else { return }
        Task {
            audioPermitted = await AudioCapture.requestAccess()
            if connection == .connected { startAudio() }
        }
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if isRecording { stopRecording() }
        audio.stop()
        device.queue.sync { device.close() }
    }

    private func onDevice<T: Sendable>(_ work: @escaping @Sendable (DeviceSession) throws -> T,
                                       then: @escaping @MainActor (Result<T, Error>) -> Void = { _ in }) {
        let device = device
        device.queue.async {
            let result = Result { try work(device) }
            Task { @MainActor in then(result) }
        }
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        let settings = DeviceSession.Settings(input: input, forcedNorm: normMode.forced, controls: controls)
        onDevice({ try $0.open(settings) }) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let norm):
                activeNorm = norm
                connection = .connected
                startAudio()
            case .failure(let error as GrabbyError) where error.isNotFound:
                connection = .searching
            case .failure(let error):
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func disconnected() {
        if isRecording { stopRecording() }
        connection = .searching
        signal = nil
        frameRate = 0
        audio.stop()
        audioAvailable = false
        onDevice { $0.close() }
    }

    private func startAudio() {
        guard audioPermitted else { return }
        audio.start { available in
            Task { @MainActor [weak self] in
                guard let self else { return }
                audioAvailable = available
                applyMonitor()
            }
        }
    }

    // MARK: - Polling

    private func tick() {
        tickCount += 1
        if isRecording, let recorder = pipeline.recorder { recordingDuration = recorder.duration }

        guard connection == .connected else {
            if tickCount % 20 == 0 { connect() }
            return
        }
        guard !busy else { return }
        let wantStatus = tickCount % 5 == 0
        busy = true
        onDevice({ device -> (Bool, SignalStatus?) in
            (try device.pollButton(), wantStatus ? try device.status() : nil)
        }) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let (pressed, status)):
                if pressed { takePhoto() }
                if let status { update(status) }
            case .failure:
                disconnected()
            }
        }
        if wantStatus {
            frameRate = pipeline.frameRate
            audioLevel = audioAvailable ? audio.level : nil
        }
    }

    private func update(_ status: SignalStatus) {
        signal = status
        guard normMode == .auto, status.locked else { return }
        let detected: VideoNorm = status.is60Hz ? .ntsc : .pal
        if detected != activeNorm { switchNorm(to: detected) }
    }

    private func switchNorm(to norm: VideoNorm) {
        if isRecording { stopRecording() }
        activeNorm = norm
        onDevice({ try $0.start(norm: norm) }) { [weak self] result in
            if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Settings

    private func save<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }

    private func applyInput() {
        let input = input
        onDevice { try $0.setInput(input) }
    }

    private func applyNormMode() {
        guard connection == .connected else { return }
        if let forced = normMode.forced {
            if forced != activeNorm { switchNorm(to: forced) }
        } else if let signal, signal.locked {
            update(signal)
        }
    }

    private func applyMonitor() {
        audio.monitorVolume = monitorAudio ? Float(monitorVolume) : 0
    }

    func value(of control: PictureControl) -> Int { controls[control] ?? control.defaultValue }

    func set(_ control: PictureControl, to value: Int) {
        controls[control] = value
        defaults.set(Dictionary(uniqueKeysWithValues: controls.map { ($0.key.title, $0.value) }), forKey: "controls")
        onDevice { try $0.set(control, value) }
    }

    func resetControls() {
        for control in PictureControl.allCases { set(control, to: control.defaultValue) }
    }

    // MARK: - Photos and recording

    static var photosFolder: URL { folder(.picturesDirectory) }
    static var moviesFolder: URL { folder(.moviesDirectory) }

    private static func folder(_ base: FileManager.SearchPathDirectory) -> URL {
        let url = FileManager.default.urls(for: base, in: .userDomainMask)[0].appending(path: "Grabby")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileName(_ ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Grabby \(formatter.string(from: Date())).\(ext)"
    }

    var canCapture: Bool { connection == .connected && frameRate > 0 }

    func takePhoto() {
        guard let frame = pipeline.latestFrame else {
            errorMessage = PhotoError.noFrame.localizedDescription
            return
        }
        let format = photoFormat
        let url = Self.photosFolder.appending(path: Self.fileName(format.fileExtension))
        flashCount += 1
        NSSound(named: "Tink")?.play()
        Task.detached(priority: .userInitiated) {
            do {
                try PhotoWriter.save(frame, format: format, to: url)
                await MainActor.run { self.lastSavedURL = url }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        let url = Self.moviesFolder.appending(path: Self.fileName("mov"))
        do {
            pipeline.recorder = try MovieRecorder(url: url, codec: codec, norm: activeNorm,
                                                  withAudio: audioAvailable)
            isRecording = true
            recordingDuration = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard let recorder = pipeline.recorder else { return }
        pipeline.recorder = nil
        isRecording = false
        isFinishingRecording = true
        Task {
            do {
                lastSavedURL = try await recorder.finish()
            } catch {
                errorMessage = error.localizedDescription
            }
            isFinishingRecording = false
        }
    }

    func revealLastSaved() {
        guard let lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL])
    }
}
