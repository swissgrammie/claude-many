import Foundation
import Observation

/// Core app logic: owns the profile list, persistence, and the lifecycle of
/// Claude processes. Kept free of SwiftUI so the whole thing is unit-testable
/// without launching Claude (the launcher is injected).
@Observable
@MainActor
final class ProfileManager {
    // MARK: Published state

    private(set) var profiles: [ClaudeProfile] = []
    private(set) var runningProfileIDs: Set<UUID> = []
    var claudeBundleURL: URL
    private(set) var lastError: String?

    // MARK: Dependencies

    let store: ProfileStore
    /// Root under which each profile's private data directory is created
    /// (`<dataRootDirectory>/<slug>`). Defaults to the app's own
    /// `Profiles` folder; injectable so tests can use scratch roots.
    let dataRootDirectory: URL
    private let launcher: any ClaudeLauncher
    private var handles: [UUID: ClaudeProcessHandle] = [:]
    /// Pending force-kill timers, one per stopped profile.
    private var forceKillTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Well-known paths

    /// `~/Library/Application Support/Claude-Many` – everything claude-many
    /// owns lives under here (profile list + per-profile data dirs).
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("Claude-Many", isDirectory: true)
    }()

    static let profilesRootDirectory: URL =
        appSupportDirectory.appendingPathComponent("Profiles", isDirectory: true)

    static let defaultBundleURL = URL(fileURLWithPath: "/Applications/Claude.app")

    var bundleExists: Bool {
        FileManager.default.fileExists(atPath: claudeBundleURL.path)
    }

    // MARK: Init

    init(
        store: ProfileStore? = nil,
        launcher: any ClaudeLauncher = RealClaudeLauncher(),
        claudeBundleURL: URL = ProfileManager.defaultBundleURL,
        dataRootDirectory: URL = ProfileManager.profilesRootDirectory
    ) {
        self.store = store
            ?? ProfileStore(fileURL: Self.appSupportDirectory.appendingPathComponent("profiles.json"))
        self.launcher = launcher
        self.claudeBundleURL = claudeBundleURL
        self.dataRootDirectory = dataRootDirectory
    }

    // MARK: Load / persist

    func load() {
        do {
            profiles = try store.load()
        } catch {
            lastError = "Could not load profiles: \(error.localizedDescription)"
            return
        }
        reconcileRunningProcesses()
    }

    /// Adopts Claude instances left over from a previous app run: any live
    /// process whose CLAUDE_USER_DATA_DIR matches a profile's data directory
    /// is tracked as that profile's running instance, so Start cannot spawn a
    /// duplicate into a data directory that is still in use.
    private func reconcileRunningProcesses() {
        let executable = claudeBundleURL.appendingPathComponent("Contents/MacOS/Claude")
        for handle in launcher.runningHandles(executable: executable) {
            guard let dataDirectory = handle.dataDirectory else { continue }
            guard let profile = profiles.first(where: {
                $0.dataDirectory.path == dataDirectory.path
            }) else { continue }
            guard handles[profile.id] == nil else { continue }
            attach(handle: handle, to: profile.id)
        }
    }

    private func persist() throws {
        try store.save(profiles)
    }

    // MARK: Profile CRUD

    @discardableResult
    func addProfile(named label: String) throws -> ClaudeProfile {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileManagerError.invalidLabel }

        let dataDirectory = try makeUniqueDataDirectory(for: trimmed)
        let profile = ClaudeProfile(label: trimmed, dataDirectory: dataDirectory)
        profiles.append(profile)
        try persist()
        return profile
    }

    func renameProfile(id: UUID, to newLabel: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileManagerError.invalidLabel }
        profiles[index].label = trimmed
        try persist()
    }

    /// Removes the profile from the list (stopping it first if running).
    /// Its data directory is deliberately left on disk: it holds the account's
    /// login and conversations, and deletion is destructive.
    func removeProfile(id: UUID) throws {
        stop(id: id)
        profiles.removeAll { $0.id == id }
        try persist()
    }

    // MARK: Start / stop

    func isRunning(id: UUID) -> Bool {
        runningProfileIDs.contains(id)
    }

    /// Launches Claude for the profile with `CLAUDE_USER_DATA_DIR` pointed at
    /// the profile's private directory, so this instance logs in independently
    /// of every other profile.
    func start(id: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        guard !isRunning(id: id) else { return }

        // stop() reports the profile as stopped immediately, but the previous
        // process can stay alive for up to the force-kill grace period.
        // Launching now would put a second instance into a data directory the
        // old process still owns.
        if let previous = handles[id], previous.isRunning {
            throw ProfileManagerError.stopInProgress
        }

        guard FileManager.default.fileExists(atPath: claudeBundleURL.path) else {
            throw ProfileManagerError.bundleMissing(path: claudeBundleURL.path)
        }

        // Create the profile's data directory lazily; Claude builds its own
        // layout (Local Storage, cookies, config, sessions) on first run.
        try FileManager.default.createDirectory(
            at: profile.dataDirectory,
            withIntermediateDirectories: true
        )

        let executable = claudeBundleURL
            .appendingPathComponent("Contents/MacOS/Claude")
        let handle = try launcher.launch(
            executable: executable,
            environment: ["CLAUDE_USER_DATA_DIR": profile.dataDirectory.path]
        )
        attach(handle: handle, to: id)
        lastError = nil
    }

    /// Registers a live handle as the running instance for a profile and
    /// observes its termination. The `isRunning` re-check after assigning the
    /// handler covers a process that exited before the handler could be set
    /// (Foundation never invokes a termination handler attached to a process
    /// that already exited).
    private func attach(handle: ClaudeProcessHandle, to id: UUID) {
        handles[id] = handle
        runningProfileIDs.insert(id)

        handle.terminationHandler = { [weak self, weak handle] in
            // Process calls the handler on an arbitrary queue; hop to the
            // main actor before touching any state. Weak captures keep the
            // handle's closure from retaining the handle itself.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let handle else { return }
                    self?.handleTermination(of: id, handle: handle)
                }
            }
        }
        if !handle.isRunning {
            handleTermination(of: id, handle: handle)
        }
    }

    /// Asks the instance to quit cleanly (SIGTERM), then force-kills it if it
    /// has not exited within a few seconds. The UI reflects "stopped"
    /// immediately; internal bookkeeping is cleaned up when the process exits.
    func stop(id: UUID) {
        guard isRunning(id: id), let handle = handles[id] else { return }
        runningProfileIDs.remove(id)
        forceKillTasks[id]?.cancel()
        handle.terminate()

        let task = Task { [weak handle] in
            try? await Task.sleep(for: .seconds(5))
            guard let handle, handle.isRunning else { return }
            handle.terminateForcefully()
        }
        forceKillTasks[id] = task
    }

    func stopAll() {
        for id in Array(runningProfileIDs) {
            stop(id: id)
        }
    }

    private func handleTermination(of id: UUID, handle: ClaudeProcessHandle) {
        // Only clean up if this is still the tracked handle for the profile:
        // a stale handle from an earlier stop could otherwise wipe out the
        // bookkeeping of a freshly restarted instance.
        guard handles[id] === handle else { return }
        handles[id] = nil
        runningProfileIDs.remove(id)
        forceKillTasks[id]?.cancel()
        forceKillTasks[id] = nil
    }

    // MARK: Settings

    func setBundlePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeBundleURL = trimmed.isEmpty
            ? Self.defaultBundleURL
            : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    func report(_ error: any Error) {
        lastError = error.localizedDescription
    }

    func clearError() {
        lastError = nil
    }

    // MARK: Helpers

    /// Builds a unique, filesystem-friendly directory name for a new profile.
    private func makeUniqueDataDirectory(for label: String) throws -> URL {
        let base = Self.slug(for: label)
        var candidate = base
        var counter = 2

        let occupied = Set(profiles.map { $0.dataDirectory.path })
        while FileManager.default.fileExists(atPath: dataRootDirectory
            .appendingPathComponent(candidate).path)
            || occupied.contains(dataRootDirectory
                .appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return dataRootDirectory.appendingPathComponent(candidate, isDirectory: true)
    }

    /// "My Work (2)" -> "my-work-2". Lowercase, non-alphanumerics become
    /// single dashes, trimmed.
    static func slug(for label: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in label.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !result.isEmpty {
                    result.append("-")
                }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if result.isEmpty { result = "profile" }
        return result
    }
}

enum ProfileManagerError: LocalizedError, Equatable {
    case invalidLabel
    case profileNotFound
    case bundleMissing(path: String)
    case stopInProgress

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "Profile name cannot be empty."
        case .profileNotFound:
            return "That profile no longer exists."
        case .bundleMissing(let path):
            return "Claude.app was not found at \(path). Install Claude Desktop or fix the path in Settings."
        case .stopInProgress:
            return "This profile's previous instance is still shutting down; try again in a moment."
        }
    }
}
