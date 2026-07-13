import SwiftUI

struct SettingsView: View {
    @State private var settings = Settings()
    @State private var outputPath: String = ""
    @State private var model: String = ""
    @State private var whisperPath: String = ""
    @State private var cleanup = true
    @State private var autoStop = false
    @State private var autoStopSecs = 30

    var body: some View {
        Form {
            HStack {
                TextField("Output folder", text: $outputPath)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    if p.runModal() == .OK, let url = p.url { outputPath = url.path }
                }
            }
            TextField("Whisper model", text: $model)
            TextField("mlx_whisper path", text: $whisperPath)
            Toggle("Clean transcript with Claude", isOn: $cleanup)
            Toggle("Auto-stop when meeting ends", isOn: $autoStop)
            if autoStop { Stepper("After \(autoStopSecs)s", value: $autoStopSecs, in: 5...120, step: 5) }
            Button("Save") {
                settings.outputFolder = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
                settings.whisperModel = model
                settings.mlxWhisperPath = whisperPath
                settings.claudeCleanupEnabled = cleanup
                settings.autoStopSeconds = autoStop ? autoStopSecs : nil
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            outputPath = settings.outputFolder.path
            model = settings.whisperModel
            whisperPath = settings.mlxWhisperPath
            cleanup = settings.claudeCleanupEnabled
            autoStop = settings.autoStopSeconds != nil
            autoStopSecs = settings.autoStopSeconds ?? 30
        }
    }
}
