import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var settings = Settings()
    @State private var outputPath = ""
    @State private var model = ""
    @State private var whisperPath = ""
    @State private var cleanup = false
    @State private var hotKeyOn = true
    @State private var launchAtLogin = false
    @State private var configurationError: String?

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
                    ForEach(WhisperModels.all) { m in
                        Text(m.displayName).tag(m.id)
                    }
                    if WhisperModels.model(id: model) == nil {
                        Text(model).tag(model)
                    }
                }
                .onChange(of: model) { old, value in
                    guard !old.isEmpty else { return }
                    if WhisperModels.isCached(value) {
                        settings.whisperModel = value
                        configurationError = nil
                    } else {
                        model = old
                        configurationError = "Download that locked model in Setup Assistant first."
                    }
                }

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

                Toggle("Send transcripts to Claude for cleanup", isOn: $cleanup)
                    .onChange(of: cleanup) { _, v in settings.claudeCleanupEnabled = v }
                Text("Sends the full transcript to your configured Claude service. Tools and session persistence are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Global shortcut \(HotKey.comboDescription) to start/stop recording", isOn: $hotKeyOn)
                    .onChange(of: hotKeyOn) { _, v in
                        settings.hotKeyEnabled = v
                        NotificationCenter.default.post(name: RecordingCoordinator.hotKeySettingChanged, object: nil)
                    }
                Toggle("Start MeetScribe at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            configurationError = error.localizedDescription
                        }
                    }
            }

            if let configurationError {
                Section {
                    Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Meetings") {
                Text("MeetScribe watches for Zoom, Slack, Chime, Teams, FaceTime and WebEx using the microphone, offers to record when a meeting starts, and stops automatically when it ends.")
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
            hotKeyOn = settings.hotKeyEnabled
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
