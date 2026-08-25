import SwiftUI

struct DestinationSettingsPane: View {
    @State private var settings = Settings()
    @State private var configuration = DestinationConfiguration()
    @State private var loaded = false
    @State private var gitStatus: ConnectionStatus = .idle
    @State private var sftpStatus: ConnectionStatus = .idle

    init(
        settings: Settings = Settings(),
        configuration: DestinationConfiguration? = nil,
        loaded: Bool = true,
        gitStatus: ConnectionStatus = .idle,
        sftpStatus: ConnectionStatus = .idle
    ) {
        _settings = State(initialValue: settings)
        _configuration = State(
            initialValue: configuration ?? settings.destinationConfiguration)
        _loaded = State(initialValue: loaded)
        _gitStatus = State(initialValue: gitStatus)
        _sftpStatus = State(initialValue: sftpStatus)
    }

    var body: some View {
        Form {
            Section("Git repository") {
                Toggle(
                    "Publish completed recordings to Git",
                    isOn: Binding(
                        get: { configuration.git.enabled },
                        set: { enabled in
                            setGitEnabled(enabled)
                        }))
                LabeledContent("Repository") {
                    HStack {
                        Text((configuration.git.repositoryPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseRepository)
                    }
                }
                TextField("Path inside repository", text: $configuration.git.relativePath)
                    .onChange(of: configuration.git.relativePath) { _, _ in gitChanged() }
                Toggle("Include recovery manifest", isOn: $configuration.git.includeManifest)
                    .onChange(of: configuration.git.includeManifest) { _, _ in save() }
                Toggle("Include raw Whisper JSON", isOn: $configuration.git.includeRawTranscript)
                    .onChange(of: configuration.git.includeRawTranscript) { _, _ in save() }
                Toggle("Include audio files", isOn: $configuration.git.includeAudio)
                    .onChange(of: configuration.git.includeAudio) { _, _ in save() }
                connectionButton(title: "Test Git repository", status: gitStatus) {
                    testGit()
                }
                Text("Markdown only is exported by default. Enabling publication requires a successful validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SFTP over SSH") {
                Toggle(
                    "Publish completed recordings over SFTP",
                    isOn: Binding(
                        get: { configuration.sftp.enabled },
                        set: { enabled in
                            setSFTPEnabled(enabled)
                        }))
                TextField("SSH host or alias", text: $configuration.sftp.host)
                    .onChange(of: configuration.sftp.host) { _, _ in sftpChanged() }
                TextField("Remote folder", text: $configuration.sftp.remotePath)
                    .onChange(of: configuration.sftp.remotePath) { _, _ in sftpChanged() }
                Toggle("Include recovery manifest", isOn: $configuration.sftp.includeManifest)
                    .onChange(of: configuration.sftp.includeManifest) { _, _ in save() }
                Toggle("Include raw Whisper JSON", isOn: $configuration.sftp.includeRawTranscript)
                    .onChange(of: configuration.sftp.includeRawTranscript) { _, _ in save() }
                Toggle("Include audio files", isOn: $configuration.sftp.includeAudio)
                    .onChange(of: configuration.sftp.includeAudio) { _, _ in save() }
                connectionButton(title: "Test SFTP connection", status: sftpStatus) {
                    testSFTP()
                }
                Text(
                    "Markdown only is exported by default. Authentication and host verification "
                        + "use an allowlisted OpenSSH environment."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            configuration.git.repositoryPath = url.path
            gitChanged()
        }
    }

    private func testGit(enableAfterSuccess: Bool = false) {
        gitStatus = .working
        var selected = configuration.git
        selected.enabled = true
        Task.detached {
            do {
                try GitRepositoryDestination(configuration: selected).validateConnection()
                await MainActor.run {
                    guard gitValidationIsCurrent(selected) else { return }
                    gitStatus = .success("Repository ready")
                    if enableAfterSuccess {
                        configuration.git.enabled = true
                        save()
                    }
                }
            } catch {
                await MainActor.run {
                    guard gitValidationIsCurrent(selected) else { return }
                    configuration.git.enabled = false
                    gitStatus = .failure(error.localizedDescription)
                    save()
                }
            }
        }
    }

    private func testSFTP(enableAfterSuccess: Bool = false) {
        sftpStatus = .working
        var selected = configuration.sftp
        selected.enabled = true
        Task.detached {
            do {
                try SFTPDestination(configuration: selected).validateConnection()
                await MainActor.run {
                    guard sftpValidationIsCurrent(selected) else { return }
                    sftpStatus = .success("Connection ready")
                    if enableAfterSuccess {
                        configuration.sftp.enabled = true
                        save()
                    }
                }
            } catch {
                await MainActor.run {
                    guard sftpValidationIsCurrent(selected) else { return }
                    configuration.sftp.enabled = false
                    sftpStatus = .failure(error.localizedDescription)
                    save()
                }
            }
        }
    }

    private func setGitEnabled(_ enabled: Bool) {
        guard enabled else {
            configuration.git.enabled = false
            gitStatus = .idle
            save()
            return
        }
        testGit(enableAfterSuccess: true)
    }

    private func setSFTPEnabled(_ enabled: Bool) {
        guard enabled else {
            configuration.sftp.enabled = false
            sftpStatus = .idle
            save()
            return
        }
        testSFTP(enableAfterSuccess: true)
    }

    private func gitChanged() {
        configuration.git.enabled = false
        gitStatus = .idle
        save()
    }

    private func sftpChanged() {
        configuration.sftp.enabled = false
        sftpStatus = .idle
        save()
    }

    private func gitValidationIsCurrent(
        _ selected: GitDestinationConfiguration
    ) -> Bool {
        DestinationValidation.isCurrent(
            current: configuration.git,
            selected: selected,
            status: gitStatus)
    }

    private func sftpValidationIsCurrent(
        _ selected: SFTPDestinationConfiguration
    ) -> Bool {
        DestinationValidation.isCurrent(
            current: configuration.sftp,
            selected: selected,
            status: sftpStatus)
    }

    private func save() {
        guard loaded else { return }
        settings.destinationConfiguration = configuration
    }

    @ViewBuilder
    private func connectionButton(
        title: String,
        status: ConnectionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Button(action: action) {
                Label(title, systemImage: "network")
            }
            .disabled(status.isWorking)
            Spacer()
            switch status {
            case .idle:
                EmptyView()
            case .working:
                ProgressView().controlSize(.small)
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }
}

enum ConnectionStatus: Equatable {
    case idle
    case working
    case success(String)
    case failure(String)

    var isWorking: Bool {
        if case .working = self { true } else { false }
    }
}

enum DestinationValidation {
    static func isCurrent(
        current: GitDestinationConfiguration,
        selected: GitDestinationConfiguration,
        status: ConnectionStatus
    ) -> Bool {
        var candidate = current
        candidate.enabled = true
        return status == .working && candidate == selected
    }

    static func isCurrent(
        current: SFTPDestinationConfiguration,
        selected: SFTPDestinationConfiguration,
        status: ConnectionStatus
    ) -> Bool {
        var candidate = current
        candidate.enabled = true
        return status == .working && candidate == selected
    }
}
