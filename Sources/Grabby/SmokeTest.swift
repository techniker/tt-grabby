import AppKit

/// `Grabby --smoke-test [seconds]` waits for video, takes a photo, records a
/// short movie, prints what it saved and quits. Used to check a build against
/// real hardware without clicking through the UI.
@MainActor
enum SmokeTest {
    static var requestedDuration: Double? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--smoke-test") else { return nil }
        return i + 1 < args.count ? Double(args[i + 1]) ?? 3 : 3
    }

    static func run(_ controller: CaptureController, seconds: Double) {
        Task {
            func log(_ s: String) { print("smoke-test: \(s)"); fflush(stdout) }
            func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                return condition()
            }

            guard await waitFor(10, { controller.canCapture }) else {
                log("no video after 10 s (connection: \(controller.connection))")
                exit(1)
            }
            try? await Task.sleep(for: .seconds(1))
            log("connected, \(controller.activeNorm.title), \(String(format: "%.1f", controller.frameRate)) fps, "
                + "signal \(controller.signal?.locked == true ? "locked" : "none"), "
                + "audio \(controller.audioAvailable ? "yes" : "no")")

            controller.takePhoto()
            _ = await waitFor(5) { controller.lastSavedURL != nil }
            log("photo \(controller.lastSavedURL?.path ?? "FAILED")")

            controller.startRecording()
            try? await Task.sleep(for: .seconds(seconds))
            controller.stopRecording()
            _ = await waitFor(10) { !controller.isFinishingRecording }
            log("movie \(controller.lastSavedURL?.path ?? "FAILED")")
            if let error = controller.errorMessage { log("error: \(error)") }
            NSApp.terminate(nil)
        }
    }
}
