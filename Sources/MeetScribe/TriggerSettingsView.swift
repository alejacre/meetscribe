import SwiftUI

struct TriggerSettingsPane: View {
    @State private var settings = Settings()
    @State private var rules: [MeetingRule] = []
    @State private var customBundleID = ""
    @State private var customName = ""
    @State private var error: String?

    init(
        settings: Settings = Settings(),
        rules: [MeetingRule] = [],
        customBundleID: String = "",
        customName: String = "",
        error: String? = nil
    ) {
        _settings = State(initialValue: settings)
        _rules = State(initialValue: rules)
        _customBundleID = State(initialValue: customBundleID)
        _customName = State(initialValue: customName)
        _error = State(initialValue: error)
    }

    var body: some View {
        Form {
            Section("Meeting applications") {
                ForEach(rules.indices, id: \.self) { index in
                    LabeledContent(rules[index].displayName) {
                        HStack(spacing: 8) {
                            Picker(rules[index].displayName, selection: binding(for: index)) {
                                ForEach(RecordingStartPolicy.allCases) { policy in
                                    Text(policy.displayName).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            if !MeetingApps.defaults.contains(where: {
                                $0.bundleID == rules[index].bundleID
                            }) {
                                Button(role: .destructive) {
                                    removeRule(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    "Remove \(rules[index].displayName)")
                                .help("Remove application")
                            }
                        }
                    }
                }
                Text("Automatic recording is opt-in per application. The menu bar indicator remains visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom application") {
                TextField("Display name", text: $customName)
                TextField("Bundle identifier", text: $customBundleID)
                    .textContentType(.none)
                Button {
                    addCustomRule()
                } label: {
                    Label("Add application", systemImage: "plus")
                }
                .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty
                    || customBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { rules = settings.meetingRules }
    }

    private func binding(for index: Int) -> Binding<RecordingStartPolicy> {
        Binding(
            get: { rules[index].policy },
            set: { value in
                rules[index].policy = value
                settings.meetingRules = rules
            })
    }

    private func addCustomRule() {
        let bundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleID.contains("."), !rules.contains(where: { $0.bundleID == bundleID }) else {
            error = "Use a unique bundle identifier such as com.example.meeting."
            return
        }
        let appName = RecordingSession.slug(displayName)
        rules.append(MeetingRule(
            bundleID: bundleID,
            displayName: displayName,
            appName: appName.isEmpty ? "meeting" : appName,
            policy: .ask))
        rules.sort {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.bundleID < $1.bundleID
        }
        settings.meetingRules = rules
        customBundleID = ""
        customName = ""
        error = nil
    }

    private func removeRule(at index: Int) {
        rules.remove(at: index)
        settings.meetingRules = rules
        error = nil
    }
}
