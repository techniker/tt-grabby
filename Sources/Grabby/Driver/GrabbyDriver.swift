import CGrabby
import Foundation

struct GrabbyError: LocalizedError {
    let code: Int32
    var errorDescription: String? { String(cString: grabby_strerror(code)) }
    var isNotFound: Bool { code == GRABBY_ERR_NOT_FOUND.rawValue }
}

enum VideoInput: String, CaseIterable, Identifiable, Codable {
    case composite, svideo
    var id: Self { self }
    var title: String { self == .composite ? "Composite" : "S-Video" }
    var cValue: grabby_input_t { self == .composite ? GRABBY_INPUT_COMPOSITE : GRABBY_INPUT_SVIDEO }
}

enum VideoNorm: String, CaseIterable, Codable {
    case pal, ntsc
    var title: String { self == .pal ? "PAL" : "NTSC" }
    var height: Int { self == .pal ? 576 : 480 }
    var frameRate: Double { self == .pal ? 25 : 30000.0 / 1001.0 }
    /// Horizontal stretch that turns 720 BT.601 samples into a 4:3 picture.
    var pixelAspect: (h: Int, v: Int) { self == .pal ? (16, 15) : (8, 9) }
    var cValue: grabby_norm_t { self == .pal ? GRABBY_NORM_PAL : GRABBY_NORM_NTSC }
}

enum PictureControl: CaseIterable, Identifiable {
    case brightness, contrast, saturation, hue, sharpness
    var id: Self { self }

    var title: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .hue: "Hue"
        case .sharpness: "Sharpness"
        }
    }

    /// Value ranges and power-on defaults of the SAA7113 registers.
    var range: ClosedRange<Int> {
        switch self {
        case .brightness: 0...255
        case .contrast, .saturation: 0...127
        case .hue: -128...127
        case .sharpness: 0...15
        }
    }

    var defaultValue: Int {
        switch self {
        case .brightness: 128
        case .contrast: 71
        case .saturation: 64
        case .hue: 0
        case .sharpness: 1
        }
    }

    var cValue: grabby_control_t {
        switch self {
        case .brightness: GRABBY_CTRL_BRIGHTNESS
        case .contrast: GRABBY_CTRL_CONTRAST
        case .saturation: GRABBY_CTRL_SATURATION
        case .hue: GRABBY_CTRL_HUE
        case .sharpness: GRABBY_CTRL_SHARPNESS
        }
    }
}

struct SignalStatus: Equatable {
    var locked: Bool
    var is60Hz: Bool
}

/// A frame delivered by the driver. The pointer is only valid inside the handler.
struct RawFrame {
    let bytes: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let stride: Int
    let hostTimeNanos: UInt64
}

/// Owns one open Grabby. Calls block on USB I/O, so use it from a background queue.
final class GrabbyDriver: @unchecked Sendable {
    private let handle: OpaquePointer
    private var frameHandler: Unmanaged<FrameHandlerBox>?

    private final class FrameHandlerBox {
        let handler: (RawFrame) -> Void
        init(_ handler: @escaping (RawFrame) -> Void) { self.handler = handler }
    }

    static func open() throws -> GrabbyDriver {
        var handle: OpaquePointer?
        try check(grabby_open(&handle))
        return GrabbyDriver(handle: handle!)
    }

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit {
        grabby_close(handle)
        frameHandler?.release()
    }

    private static func check(_ result: Int32) throws {
        if result < 0 { throw GrabbyError(code: result) }
    }

    var norm: VideoNorm { grabby_get_norm(handle) == GRABBY_NORM_NTSC ? .ntsc : .pal }
    var isStreaming: Bool { grabby_is_streaming(handle) }

    func setInput(_ input: VideoInput) throws { try Self.check(grabby_set_input(handle, input.cValue)) }
    func setNorm(_ norm: VideoNorm) throws { try Self.check(grabby_set_norm(handle, norm.cValue)) }

    func set(_ control: PictureControl, _ value: Int) throws {
        try Self.check(grabby_set_control(handle, control.cValue, Int32(value)))
    }

    func status() throws -> SignalStatus {
        var s = grabby_status_t()
        try Self.check(grabby_get_status(handle, &s))
        return SignalStatus(locked: s.signal_locked, is60Hz: s.is_60hz)
    }

    func pollButton() throws -> Bool {
        let r = grabby_poll_button(handle)
        try Self.check(r)
        return r == 1
    }

    var stats: grabby_stats_t {
        var s = grabby_stats_t()
        grabby_get_stats(handle, &s)
        return s
    }

    /// Starts streaming. `handler` runs on the driver's USB thread.
    func start(_ handler: @escaping (RawFrame) -> Void) throws {
        let box = Unmanaged.passRetained(FrameHandlerBox(handler))
        let callback: grabby_frame_cb = { ctx, bytes, width, height, stride, ts in
            let box = Unmanaged<FrameHandlerBox>.fromOpaque(ctx!).takeUnretainedValue()
            box.handler(RawFrame(bytes: bytes!, width: Int(width), height: Int(height),
                                 stride: Int(stride), hostTimeNanos: ts))
        }
        let result = grabby_start(handle, callback, box.toOpaque())
        if result < 0 {
            box.release()
            throw GrabbyError(code: result)
        }
        frameHandler?.release()
        frameHandler = box
    }

    func stop() {
        grabby_stop(handle)
        frameHandler?.release()
        frameHandler = nil
    }
}
