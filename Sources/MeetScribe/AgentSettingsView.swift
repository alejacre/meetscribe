import SwiftUI

struct AgentSettingsPane: View {
    @State private var settings = Settings()
    @State private var configuration = AgentConfiguration.disabled
    @State private var argumentsText = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Transcript processing") {
                Picker("Agent", selection: $configuration.provider) {
                    ForEach(AgentProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: configuration.provider) { _, _ in save() }

                switch configuration.provider {
                case .disabled:
                    Text("Transcripts stay as locally generated Whisper output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .claudeCode:
                    Text(
                        "Uses the local Claude Code CLI with tools and session persistence disabled. "
                            + "The complete transcript is sent to the service configured by that CLI."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .customCommand:
                    customCommandFields
                }
            }

            Section("Adapter contract") {
                Text(
                    "MeetScribe writes the transcript to stdin. Arguments are passed directly without "
                        + "a shell. Use {prompt} in one argument; otherwise the prompt is appended. "
                        + "The command must return validated MeetScribe Markdown on stdout."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            configuration = settings.agentConfiguration
            argumentsText = configuration.customArguments.joined(separator: "\n")
            loaded = true
        }
    }

    @ViewBuilder
    private var customCommandFields: some View {
        LabeledContent("Executable") {
            HStack {
                Text((configuration.customExecutable as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: chooseExecutable)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Arguments, one per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $argumentsText)
                .font(.body.monospaced())
                .frame(height: 100)
                .onChange(of: argumentsText) { _, value in
                    configuration.customArguments = value
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                        .filter { !$0.isEmpty }
                    save()
                }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $configuration.customPrompt)
                .font(.body.monospaced())
                .frame(height: 120)
                .onChange(of: configuration.customPrompt) { _, _ in save() }
        }
        Toggle(
            "Allow the command to inherit the full process environment",
            isOn: $configuration.inheritEnvironment
        )
        .onChange(of: configuration.inheritEnvironment) { _, _ in save() }
        Text(
            configuration.inheritEnvironment
                ? "Environment variables may include credentials. Enable this only for an agent that requires them."
                : "Default: only HOME, PATH, TMPDIR, LANG and USER are provided."
        )
        .font(.caption)
        .foregroundStyle(configuration.inheritEnvironment ? .orange : .secondary)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            configuration.customExecutable = url.path
            save()
        }
    }

    private func save() {
        guard loaded else { return }
        settings.agentConfiguration = configuration
    }
}
