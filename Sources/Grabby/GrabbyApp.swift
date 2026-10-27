import SwiftUI

@main
struct GrabbyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Grabby", id: "main") {
            ContentView()
                .environment(appDelegate.controller)
                .onAppear { appDelegate.controller.activate() }
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CaptureCommands(controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CaptureController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbundled builds (`swift run`) start as background processes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let seconds = SmokeTest.requestedDuration {
            controller.activate()
            SmokeTest.run(controller, seconds: seconds)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRecording else {
            controller.shutdown()
            return .terminateNow
        }
        // Let the movie file finish writing before quitting.
        controller.stopRecording()
        Task {
            while controller.isFinishingRecording { try? await Task.sleep(for: .milliseconds(50)) }
            controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct CaptureCommands: Commands {
    let controller: CaptureController

    var body: some Commands {
        CommandMenu("Capture") {
            Button("Take Photo") { controller.takePhoto() }
                .keyboardShortcut("t")
                .disabled(!controller.canCapture)
            Button(controller.isRecording ? "Stop Recording" : "Start Recording") {
                controller.toggleRecording()
            }
            .keyboardShortcut("r")
            .disabled(!controller.canCapture && !controller.isRecording)
            Divider()
            Button("Show Photos in Finder") { NSWorkspace.shared.open(CaptureController.photosFolder) }
            Button("Show Movies in Finder") { NSWorkspace.shared.open(CaptureController.moviesFolder) }
        }
    }
}
