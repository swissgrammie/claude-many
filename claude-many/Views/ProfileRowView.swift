import SwiftUI

struct ProfileRowView: View {
    @Bindable var manager: ProfileManager
    let profile: ClaudeProfile

    @State private var showingRenameAlert = false
    @State private var renameText = ""
    @State private var showingDeleteConfirm = false

    private var isRunning: Bool { manager.isRunning(id: profile.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
                .accessibilityLabel(isRunning ? "Running" : "Stopped")

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label)
                    .font(.headline)
                Text(profile.dataDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .alert("Rename Profile", isPresented: $showingRenameAlert) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    do { try manager.renameProfile(id: profile.id, to: renameText) }
                    catch { manager.report(error) }
                }
                Button("Cancel", role: .cancel) {}
            }

            Spacer()

            if isRunning {
                Button("Stop") {
                    manager.stop(id: profile.id)
                }
                .buttonStyle(.bordered)
                .help("Quit this Claude instance")
            } else {
                Button("Start") {
                    do { try manager.start(id: profile.id) }
                    catch { manager.report(error) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.bundleExists)
                .help("Launch Claude Desktop with this profile's data directory")
            }

            Menu {
                Button("Rename…") {
                    renameText = profile.label
                    showingRenameAlert = true
                }
                Divider()
                Button("Delete", role: .destructive) {
                    showingDeleteConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 16)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .confirmationDialog(
            "Delete “\(profile.label)”?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                do { try manager.removeProfile(id: profile.id) }
                catch { manager.report(error) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The profile is removed from the list. Its data directory stays on disk so nothing is lost.")
        }
        .padding(.vertical, 4)
    }
}
