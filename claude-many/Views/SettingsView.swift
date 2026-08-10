import SwiftUI

struct SettingsView: View {
    @Bindable var manager: ProfileManager
    @State private var path = ""

    var body: some View {
        Form {
            Section("Claude Application") {
                TextField("Path to Claude.app", text: $path)
                    .onChange(of: path) { _, newValue in
                        manager.setBundlePath(newValue)
                    }
                HStack {
                    Button("Reset to Default") {
                        manager.setBundlePath(ProfileManager.defaultBundleURL.path)
                        path = manager.claudeBundleURL.path
                    }
                    Spacer()
                    Label(
                        manager.bundleExists ? "Claude.app found" : "Claude.app not found",
                        systemImage: manager.bundleExists
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(manager.bundleExists ? .green : .orange)
                }
            }

            Section("Where data lives") {
                LabeledContent("Profiles directory") {
                    Text(ProfileManager.profilesRootDirectory.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("Every profile keeps all of its account data in its own private directory under ~/Library/Application Support/Claude-Many/Profiles. Nothing is ever written to the shared ~/Library/Application Support/Claude folder, and no data ever leaves this machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear { path = manager.claudeBundleURL.path }
    }
}
