import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            TriggerSettingsPane()
                .tabItem { Label("Triggers", systemImage: "record.circle") }
            AgentSettingsPane()
                .tabItem { Label("Agent", systemImage: "wand.and.stars") }
            DestinationSettingsPane()
                .tabItem { Label("Destinations", systemImage: "externaldrive.connected.to.line.below") }
        }
        .frame(width: 640, height: 520)
    }
}

private struct GeneralSettingsPane: View {
    @State private var settings = Settings()
    @State private var outputPath = ""
    @State private var model = ""
    @State private var whisperPath = ""
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
                        Button("Choose…", action: chooseOutputFolder)
                    }
                }
                Text("Recordings are always staged locally before optional Git or SFTP publishing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Whisper model", selection: $model) {
                    ForEach(WhisperModels.all) { item in
                        Text(item.displayName).tag(item.id)
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
                        Button("Choose…", action: chooseWhisper)
                    }
                }
            }

            Section("Application") {
                Toggle(
                    "Global shortcut \(HotKey.comboDescription) to start/stop recording",
                    isOn: $hotKeyOn
                )
                .onChange(of: hotKeyOn) { _, value in
                    settings.hotKeyEnabled = value
                    NotificationCenter.default.post(
                        name: RecordingCoordinator.hotKeySettingChanged,
                        object: nil)
                }
                Toggle("Start MeetScribe at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            if value { try SMAppService.mainApp.register() }
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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            outputPath = settings.outputFolder.path
            model = settings.whisperModel
            whisperPath = settings.mlxWhisperPath
            hotKeyOn = settings.hotKeyEnabled
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: outputPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
            settings.outputFolder = url
        }
    }

    private func chooseWhisper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            whisperPath = url.path
            settings.mlxWhisperPath = url.path
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
