import Foundation

/// Everything that touches the USB device, confined to one serial queue so
/// blocking control transfers never run on the main thread.
final class DeviceSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "grabby.device", qos: .userInitiated)
    private let pipeline: FramePipeline
    private var driver: GrabbyDriver?

    init(pipeline: FramePipeline) { self.pipeline = pipeline }

    var isOpen: Bool { driver != nil }

    struct Settings: Sendable {
        var input: VideoInput
        var forcedNorm: VideoNorm?
        var controls: [PictureControl: Int]
    }

    /// Opens the device, applies settings and starts streaming. Returns the active norm.
    func open(_ settings: Settings) throws -> VideoNorm {
        let driver = try GrabbyDriver.open()
        try driver.setInput(settings.input)
        for (control, value) in settings.controls { try driver.set(control, value) }
        if let norm = settings.forcedNorm { try driver.setNorm(norm) }
        self.driver = driver
        try start(norm: driver.norm)
        return driver.norm
    }

    func close() {
        driver?.stop()
        driver = nil
        pipeline.reset()
    }

    func start(norm: VideoNorm) throws {
        guard let driver else { return }
        driver.stop()
        try driver.setNorm(norm)
        pipeline.norm = norm
        pipeline.reset()
        try driver.start { [pipeline] in pipeline.handle($0) }
    }

    func setInput(_ input: VideoInput) throws { try driver?.setInput(input) }
    func set(_ control: PictureControl, _ value: Int) throws { try driver?.set(control, value) }

    func pollButton() throws -> Bool { try driver?.pollButton() ?? false }
    func status() throws -> SignalStatus? { try driver?.status() }
}
