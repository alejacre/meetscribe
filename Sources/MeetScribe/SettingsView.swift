import SwiftUI

struct SettingsView: View {
    @State private var settings = Settings()
    @State private var outputPath = ""
    @State private var model = ""
    @State private var whisperPath = ""
    @State private var cleanup = true
    @State private var autoStop = false
    @State private var autoStopSecs = 30

    private static let models = [
        "mlx-community/whisper-large-v3-turbo",
        "mlx-community/whisper-large-v3-mlx",
        "mlx-community/whisper-medium-mlx",
        "mlx-community/whisper-small-mlx",
    ]

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Output folder") {
                    HStack(spacing: 8) {
                        Text(abbreviated(outputPath))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            p.directoryURL = URL(fileURLWithPath: outputPath)
                            if p.runModal() == .OK, let url = p.url {
                                outputPath = url.path
                                settings.outputFolder = url
                            }
                        }
                    }
                }
            }

            Section("Transcription") {
                Picker("Whisper model", selection: $model) {
                    ForEach(Self.models, id: \.self) { m in
                        Text(m.replacingOccurrences(of: "mlx-community/", with: "")).tag(m)
                    }
                    if !Self.models.contains(model) {
                        Text(model).tag(model)
                    }
                }
                .onChange(of: model) { _, v in settings.whisperModel = v }

                LabeledContent("mlx_whisper") {
                    HStack(spacing: 8) {
                        Text(abbreviated(whisperPath))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = true
                            p.canChooseDirectories = false
                            p.showsHiddenFiles = true
                            if p.runModal() == .OK, let url = p.url {
                                whisperPath = url.path
                                settings.mlxWhisperPath = url.path
                            }
                        }
                    }
                }

                Toggle("Clean transcript with Claude", isOn: $cleanup)
                    .onChange(of: cleanup) { _, v in settings.claudeCleanupEnabled = v }
                Text("Adds a summary, fixes punctuation, removes filler words, and names the folder after the meeting topic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Meetings") {
                Toggle("Auto-stop when meeting ends", isOn: $autoStop)
                    .onChange(of: autoStop) { _, v in
                        settings.autoStopSeconds = v ? autoStopSecs : nil
                    }
                if autoStop {
                    Stepper("Stop after \(autoStopSecs) seconds", value: $autoStopSecs, in: 5...120, step: 5)
                        .onChange(of: autoStopSecs) { _, v in settings.autoStopSeconds = v }
                }
                Text("MeetScribe watches for Zoom, Slack, Chime, Teams, FaceTime and WebEx using the microphone and offers to record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            outputPath = settings.outputFolder.path
            model = settings.whisperModel
            whisperPath = settings.mlxWhisperPath
            cleanup = settings.claudeCleanupEnabled
            autoStop = settings.autoStopSeconds != nil
            autoStopSecs = settings.autoStopSeconds ?? 30
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}
