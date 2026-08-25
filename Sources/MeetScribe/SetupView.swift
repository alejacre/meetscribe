import SwiftUI

struct SetupView: View {
    @StateObject private var model: SetupModel
    @Environment(\.dismiss) private var dismiss

    init(model: SetupModel = SetupModel()) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { stepBody.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 300)
            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.beginChecks()
        }
        .onDisappear { model.cancelWork() }
    }

    // MARK: Header (step dots)

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= model.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Spacer()
            Text(model.step.title)
                .font(.headline)
                .accessibilityLabel(
                    "Step \(model.step.rawValue + 1) of \(SetupStep.allCases.count): \(model.step.title)")
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: Step bodies

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome: welcomeStep
        case .engine: engineStep
        case .model: modelStep
        case .permissions: permissionsStep
        case .output: outputStep
        case .cleanup: cleanupStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to MeetScribe").font(.title2).bold()
            Text(
                "MeetScribe records meetings and transcribes them locally on your Mac. "
                    + "An optional transcript agent can process the result after you explicitly enable it."
            )
                .foregroundStyle(.secondary)
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MeetScribe transcribes with MLX Whisper, which runs on Apple Silicon.")
                .foregroundStyle(.secondary)
            switch model.enginePhase {
            case .checking:
                Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .done:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let p = model.resolvedEnginePath {
                    Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case .missing:
                Text("Not found. MeetScribe can install it with an existing **uv** installation.")
                Button("Install mlx-whisper") { model.installEngine() }
                    .buttonStyle(.borderedProminent)
            case .working:
                ProgressLogView(log: model.engineLog, progress: model.engineProgress,
                                caption: "Installing…")
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try again") { model.installEngine() }
                ProgressLogView(log: model.engineLog, progress: nil, caption: nil)
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Model", selection: Binding(
                get: { model.selectedModel },
                set: { model.selectModel($0) })) {
                ForEach(WhisperModels.all) { m in
                    Text(m.displayName).tag(m.id)
                }
            }
            .disabled(model.modelPhase == .working)

            switch model.modelPhase {
            case .checking:
                Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .done:
                Label("Already downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Text("The model downloads once (~1.5 GB for turbo) so your first real transcription is fast.")
                    .foregroundStyle(.secondary)
                Button("Download model") { model.downloadModel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engineReady)
                if !engineReady {
                    Text("Install the transcription engine first.").font(.caption).foregroundStyle(.orange)
                }
            case .working:
                ProgressLogView(log: model.modelLog, progress: model.modelProgress, caption: "Downloading…")
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try again") { model.downloadModel() }.disabled(!engineReady)
                ProgressLogView(log: model.modelLog, progress: nil, caption: nil)
            }
        }
    }

    private var engineReady: Bool { if case .done = model.enginePhase { return true }; return false }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            permRow(title: "Screen Recording", subtitle: "Captures what other people say (system audio).",
                    state: model.screenPerm, request: model.requestScreen,
                    open: { Permissions.openPrivacyPane("Privacy_ScreenCapture") })
            if model.screenPerm != .granted {
                Text("If you just granted it, you may need to quit and reopen MeetScribe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            permRow(title: "Microphone", subtitle: "Captures your voice.",
                    state: model.micPerm, request: model.requestMic,
                    open: { Permissions.openPrivacyPane("Privacy_Microphone") })
            permRow(title: "Notifications", subtitle: "Prompts to record and status updates.",
                    state: model.notifPerm, request: model.requestNotifications,
                    open: { Permissions.openNotificationSettings() })
            Button("Check again") { Task { await model.refreshPermissions() } }
        }
    }

    private func permRow(title: String, subtitle: String, state: PermState,
                         request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: state == .granted ? "checkmark.circle.fill"
                  : state == .denied ? "xmark.circle.fill" : "circle")
                .foregroundStyle(state == .granted ? .green : state == .denied ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Text("Granted").font(.caption).foregroundStyle(.green)
            } else if state == .denied {
                Button("Open Settings", action: open)
            } else {
                Button("Grant", action: request)
            }
        }
    }

    private var outputStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where should MeetScribe save transcripts and audio?").foregroundStyle(.secondary)
            HStack {
                Text((model.outputPath as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = URL(fileURLWithPath: model.outputPath)
                    if p.runModal() == .OK, let url = p.url { model.setOutput(url) }
                }
            }
            Text("Point this at an Obsidian vault folder to drop meeting notes straight in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cleanupStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Optionally process transcripts with Claude Code or Kiro CLI. The complete transcript "
                    + "is sent to the service configured by the selected local CLI."
            )
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                toolStatus(name: "Claude", found: model.claudeFound)
                toolStatus(name: "Kiro", found: model.kiroFound)
            }
            Picker("Transcript agent", selection: Binding(
                get: { model.agentProvider },
                set: { model.setAgentProvider($0) }))
            {
                Text(AgentProviderKind.disabled.displayName)
                    .tag(AgentProviderKind.disabled)
                Text(AgentProviderKind.claudeCode.displayName)
                    .tag(AgentProviderKind.claudeCode)
                    .disabled(model.claudeFound == false)
                Text(AgentProviderKind.kiroCLI.displayName)
                    .tag(AgentProviderKind.kiroCLI)
                    .disabled(model.kiroFound == false)
                if model.agentProvider == .customCommand {
                    Text(AgentProviderKind.customCommand.displayName)
                        .tag(AgentProviderKind.customCommand)
                }
            }
            cleanupProviderDescription
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var cleanupProviderDescription: Text {
        switch model.agentProvider {
        case .disabled:
            Text("No agent is used; the local Whisper transcript is kept unchanged.")
        case .claudeCode:
            Text("Claude runs with the Haiku model, tools and session persistence disabled.")
        case .kiroCLI:
            Text("Kiro runs without tools; MeetScribe deletes its temporary local session afterward.")
        case .customCommand:
            Text("The custom command remains configured. Edit it later in Settings > Agent.")
        }
    }

    @ViewBuilder
    private func toolStatus(name: String, found: Bool?) -> some View {
        switch found {
        case .some(true):
            Label("\(name) found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(false):
            Label("\(name) not found", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're all set", systemImage: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
            Text("MeetScribe lives in your menu bar. It'll offer to record when it sees a meeting, or press ⌥⇧R to start anytime.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            if model.step == .done {
                Button("Finish") { model.finish(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.requiredSetupComplete)
            } else {
                if model.step == .cleanup {
                    Button("Skip") { move(1) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func move(_ delta: Int) {
        let next = model.step.rawValue + delta
        guard let s = SetupStep(rawValue: next) else { return }
        model.step = s
        model.onEnter(s)
    }

    private var canContinue: Bool {
        switch model.step {
        case .engine: if case .done = model.enginePhase { return true }; return false
        case .model: if case .done = model.modelPhase { return true }; return false
        case .permissions: return model.screenPerm == .granted && model.micPerm == .granted
        default: return true
        }
    }
}

/// Determinate bar when a percentage is known, else a spinner, above a live,
/// auto-scrolling monospaced log tail.
struct ProgressLogView: View {
    let log: String
    let progress: Int?
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption {
                if let progress {
                    ProgressView(value: Double(progress), total: 100) { Text(caption) }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(caption) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? " " : log)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logEnd")
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
        }
    }
}
