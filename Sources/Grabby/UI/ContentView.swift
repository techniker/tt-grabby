import SwiftUI

struct ContentView: View {
    @Environment(CaptureController.self) private var controller
    @State private var flash = false

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                videoArea
                StatusBar()
            }
            Divider()
            SettingsPanel()
                .frame(width: 290)
        }
        .toolbar { toolbar }
        .onChange(of: controller.flashCount) {
            flash = true
            withAnimation(.easeOut(duration: 0.35)) { flash = false }
        }
        .alert("Grabby", isPresented: Binding(get: { controller.errorMessage != nil },
                                              set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoPreview(layer: controller.pipeline.displayLayer)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay { Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false) }
            overlayMessage
            if controller.isRecording {
                RecordingBadge(duration: controller.recordingDuration)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var overlayMessage: some View {
        switch controller.connection {
        case .searching:
            MessageCard(symbol: "cable.connector", title: "Connect your TerraTec Grabby",
                        detail: "Plug the Grabby into a USB port. It will be picked up automatically.")
        case .failed(let reason):
            MessageCard(symbol: "exclamationmark.triangle", title: "The Grabby could not be opened",
                        detail: reason)
        case .connected:
            if let signal = controller.signal, !signal.locked {
                MessageCard(symbol: "antenna.radiowaves.left.and.right.slash", title: "No video signal",
                            detail: "Check the cable and that the \(controller.input.title) input is selected.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.takePhoto()
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            .help("Take a photo (⌘T or the button on the Grabby)")
            .disabled(!controller.canCapture)

            Button {
                controller.toggleRecording()
            } label: {
                Label(controller.isRecording ? "Stop Recording" : "Record",
                      systemImage: controller.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(controller.isRecording ? .red : .primary)
            }
            .help(controller.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
            .disabled(!controller.canCapture && !controller.isRecording)

            Button {
                controller.revealLastSaved()
            } label: {
                Label("Show Last Capture", systemImage: "folder")
            }
            .help("Show the last photo or movie in Finder")
            .disabled(controller.lastSavedURL == nil)
        }
    }
}

private struct MessageCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct RecordingBadge: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(Self.format(duration)).font(.system(.callout, design: .monospaced).weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct StatusBar: View {
    @Environment(CaptureController.self) private var controller

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(indicatorColor).frame(width: 8, height: 8)
                Text(statusText)
            }
            if controller.connection == .connected {
                Text("\(controller.activeNorm.title) 720×\(controller.activeNorm.height)")
                Text(String(format: "%.1f fps", controller.frameRate)).monospacedDigit()
            }
            Spacer()
            if controller.audioAvailable {
                AudioMeter(level: controller.audioLevel)
            } else if controller.connection == .connected {
                Text("No audio").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var indicatorColor: Color {
        switch controller.connection {
        case .connected: controller.signal?.locked == true ? .green : .orange
        case .searching: .gray
        case .failed: .red
        }
    }

    private var statusText: String {
        switch controller.connection {
        case .searching: "Not connected"
        case .failed: "Error"
        case .connected: controller.signal?.locked == true ? "Signal" : "No signal"
        }
    }
}

private struct AudioMeter: View {
    let level: Float?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(fraction > 0.9 ? Color.red : Color.green)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 90, height: 6)
        }
        .help("Audio level from the Grabby")
    }

    /// Maps -60...0 dBFS to 0...1.
    private var fraction: CGFloat {
        guard let level else { return 0 }
        return CGFloat(max(0, min(1, (level + 60) / 60)))
    }
}
