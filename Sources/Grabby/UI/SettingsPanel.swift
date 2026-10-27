import SwiftUI

struct SettingsPanel: View {
    @Environment(CaptureController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section("Source") {
                Picker("Input", selection: $controller.input) {
                    ForEach(VideoInput.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Video standard", selection: $controller.normMode) {
                    ForEach(NormMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Deinterlace", selection: $controller.deinterlace) {
                    ForEach(Deinterlace.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                ForEach(PictureControl.allCases) { control in
                    ControlSlider(control: control)
                }
                Button("Reset Picture") { controller.resetControls() }
            } header: {
                Text("Picture")
            }

            Section("Audio") {
                Toggle("Listen through speakers", isOn: $controller.monitorAudio)
                    .disabled(!controller.audioAvailable)
                Slider(value: $controller.monitorVolume, in: 0...1) {
                    Text("Volume")
                }
                .disabled(!controller.audioAvailable || !controller.monitorAudio)
            }

            Section("Saving") {
                Picker("Movie format", selection: $controller.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
                .disabled(controller.isRecording)
                Picker("Photo format", selection: $controller.photoFormat) {
                    ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Photos") {
                    Button("~/Pictures/Grabby") { NSWorkspace.shared.open(CaptureController.photosFolder) }
                        .buttonStyle(.link)
                }
                LabeledContent("Movies") {
                    Button("~/Movies/Grabby") { NSWorkspace.shared.open(CaptureController.moviesFolder) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(controller.connection != .connected)
    }
}

private struct ControlSlider: View {
    @Environment(CaptureController.self) private var controller
    let control: PictureControl

    var body: some View {
        let value = Binding<Double>(
            get: { Double(controller.value(of: control)) },
            set: { controller.set(control, to: Int($0.rounded())) }
        )
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.title)
                Spacer()
                Text("\(controller.value(of: control))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: Double(control.range.lowerBound)...Double(control.range.upperBound), step: 1)
                .labelsHidden()
        }
        .contextMenu {
            Button("Reset \(control.title)") { controller.set(control, to: control.defaultValue) }
        }
    }
}
