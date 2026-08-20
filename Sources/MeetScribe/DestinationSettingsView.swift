import SwiftUI

struct DestinationSettingsPane: View {
    @State private var settings = Settings()
    @State private var configuration = DestinationConfiguration()
    @State private var loaded = false
    @State private var gitStatus: ConnectionStatus = .idle
    @State private var sftpStatus: ConnectionStatus = .idle

    init(
        settings: Settings = Settings(),
        configuration: DestinationConfiguration = DestinationConfiguration(),
        loaded: Bool = false,
        gitStatus: ConnectionStatus = .idle,
        sftpStatus: ConnectionStatus = .idle
    ) {
        _settings = State(initialValue: settings)
        _configuration = State(initialValue: configuration)
        _loaded = State(initialValue: loaded)
        _gitStatus = State(initialValue: gitStatus)
        _sftpStatus = State(initialValue: sftpStatus)
    }

    var body: some View {
        Form {
            Section("Git repository") {
                Toggle("Publish completed recordings to Git", isOn: $configuration.git.enabled)
                    .onChange(of: configuration.git.enabled) { _, _ in save() }
                if configuration.git.enabled {
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
                        .onChange(of: configuration.git.relativePath) { _, _ in save() }
                    Toggle("Include audio files", isOn: $configuration.git.includeAudio)
                        .onChange(of: configuration.git.includeAudio) { _, _ in save() }
                    connectionButton(title: "Test Git repository", status: gitStatus) {
                        testGit()
                    }
                    Text("The repository must be clean except for files belonging to the recording being retried.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("SFTP over SSH") {
                Toggle("Publish completed recordings over SFTP", isOn: $configuration.sftp.enabled)
                    .onChange(of: configuration.sftp.enabled) { _, _ in save() }
                if configuration.sftp.enabled {
                    TextField("SSH host or alias", text: $configuration.sftp.host)
                        .onChange(of: configuration.sftp.host) { _, _ in save() }
                    TextField("Remote folder", text: $configuration.sftp.remotePath)
                        .onChange(of: configuration.sftp.remotePath) { _, _ in save() }
                    Toggle("Include audio files", isOn: $configuration.sftp.includeAudio)
                        .onChange(of: configuration.sftp.includeAudio) { _, _ in save() }
                    connectionButton(title: "Test SFTP connection", status: sftpStatus) {
                        testSFTP()
                    }
                    Text(
                        "Authentication and host verification use your OpenSSH configuration. "
                            + "MeetScribe never stores private keys or passwords."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            configuration = settings.destinationConfiguration
            loaded = true
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            configuration.git.repositoryPath = url.path
            gitStatus = .idle
            save()
        }
    }

    private func testGit() {
        gitStatus = .working
        let selected = configuration.git
        Task.detached {
            do {
                try GitRepositoryDestination(configuration: selected).validateConnection()
                await MainActor.run { gitStatus = .success("Repository ready") }
            } catch {
                await MainActor.run { gitStatus = .failure(error.localizedDescription) }
            }
        }
    }

    private func testSFTP() {
        sftpStatus = .working
        let selected = configuration.sftp
        Task.detached {
            do {
                try SFTPDestination(configuration: selected).validateConnection()
                await MainActor.run { sftpStatus = .success("Connection ready") }
            } catch {
                await MainActor.run { sftpStatus = .failure(error.localizedDescription) }
            }
        }
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
