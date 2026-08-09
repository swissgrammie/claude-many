import SwiftUI

struct ContentView: View {
    @Bindable var manager: ProfileManager
    @State private var showingAddAlert = false
    @State private var newProfileName = ""

    var body: some View {
        NavigationStack {
            Group {
                if manager.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "person.2")
                    } description: {
                        Text("Add one profile per Claude account.\nEach profile runs its own Claude Desktop instance with its own login.")
                    } actions: {
                        Button("Add Profile") {
                            newProfileName = ""
                            showingAddAlert = true
                        }
                    }
                } else {
                    List {
                        ForEach(manager.profiles) { profile in
                            ProfileRowView(manager: manager, profile: profile)
                        }
                    }
                }
            }
            .navigationTitle("Claude Many")
            .toolbar {
                ToolbarItem {
                    Button {
                        newProfileName = ""
                        showingAddAlert = true
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .help("Add a profile for another Claude account")
                }
            }
            .alert("Add Profile", isPresented: $showingAddAlert) {
                TextField("Name (e.g. Work, Personal)", text: $newProfileName)
                Button("Add") { addProfile() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each profile gets its own private data directory.")
            }
        }
        .alert(
            "Something went wrong",
            isPresented: errorBinding
        ) {
            Button("OK", role: .cancel) { manager.clearError() }
        } message: {
            Text(manager.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.clearError() } }
        )
    }

    private func addProfile() {
        do {
            try manager.addProfile(named: newProfileName)
        } catch {
            manager.report(error)
        }
    }
}
