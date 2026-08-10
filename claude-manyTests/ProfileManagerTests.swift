import XCTest
@testable import claude_many

/// Records launches instead of spawning real processes, so the manager's
/// behavior can be tested without touching Claude. Only ever touched from
/// the main actor (the manager and the tests are both main-actor isolated),
/// so unchecked Sendable is safe here.
final class FakeClaudeLauncher: ClaudeLauncher, @unchecked Sendable {
    struct LaunchRecord: Equatable {
        let executable: URL
        let environment: [String: String]
    }

    private(set) var launches: [LaunchRecord] = []
    private(set) var launchedHandles: [FakeClaudeProcess] = []
    var shouldThrow: (any Error)?
    /// Handles `runningHandles(executable:)` returns, simulating live Claude
    /// processes discovered at load time (e.g. left over from a relaunch).
    var runningHandlesToReturn: [FakeClaudeProcess] = []
    /// When true, a launched process is already dead by the time launch()
    /// returns (it exited before the manager could attach its handler).
    var launchReturnsDeadHandle = false

    func launch(executable: URL, environment: [String: String]) throws -> ClaudeProcessHandle {
        if let shouldThrow { throw shouldThrow }
        launches.append(LaunchRecord(executable: executable, environment: environment))
        let handle = FakeClaudeProcess()
        launchedHandles.append(handle)
        if launchReturnsDeadHandle {
            handle.simulateExit()
        }
        return handle
    }

    func runningHandles(executable: URL) -> [ClaudeProcessHandle] {
        runningHandlesToReturn
    }
}

final class FakeClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    var processIdentifier: Int32 { 4242 }
    let dataDirectory: URL?
    private(set) var terminationRequested = false
    private(set) var forceKilled = false
    private(set) var exited = false
    var terminationHandler: (@Sendable () -> Void)?

    /// Models reality: SIGTERM leaves the process alive until it actually
    /// exits, so terminate() does not end the process by itself.
    var isRunning: Bool { !exited }

    init(dataDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
    }

    func terminate() { terminationRequested = true }
    func terminateForcefully() { forceKilled = true; exited = true }

    /// Simulates the process exiting on its own (after SIGTERM or on its own).
    func simulateExit() {
        exited = true
        terminationHandler?()
    }
}

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var tempDir: URL!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-mgr-\(UUID().uuidString)", isDirectory: true)
        launcher = FakeClaudeLauncher()
        manager = makeManager()
    }

    override func tearDown() async throws {
        manager.stopAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(
            store: ProfileStore(fileURL: tempDir.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: tempDir.appendingPathComponent("Claude.app"),
            dataRootDirectory: tempDir.appendingPathComponent("Profiles")
        )
    }

    private func makeBundle() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Claude.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: Slugging

    func testSlugGeneration() {
        XCTAssertEqual(ProfileManager.slug(for: "My Work"), "my-work")
        XCTAssertEqual(ProfileManager.slug(for: "My  Work!! (2)"), "my-work-2")
        XCTAssertEqual(ProfileManager.slug(for: "Ötzi's äccount"), "ötzi-s-äccount")
        XCTAssertEqual(ProfileManager.slug(for: "   "), "profile")
        XCTAssertEqual(ProfileManager.slug(for: "Claude"), "claude")
    }

    // MARK: Add / rename / remove

    func testAddProfileCreatesUniqueDataDirsUnderProfilesRoot() throws {
        let p1 = try manager.addProfile(named: "Work")
        let p2 = try manager.addProfile(named: "Personal")
        let p3 = try manager.addProfile(named: "Work") // same label -> unique dir

        XCTAssertEqual(manager.profiles.count, 3)
        let slash = CharacterSet(charactersIn: "/")
        XCTAssertEqual(p1.dataDirectory.deletingLastPathComponent().path.trimmingCharacters(in: slash),
                       manager.dataRootDirectory.path.trimmingCharacters(in: slash))
        XCTAssertEqual(p2.dataDirectory.lastPathComponent, "personal")
        XCTAssertEqual(p3.dataDirectory.lastPathComponent, "work-2")
        XCTAssertNotEqual(p1.dataDirectory, p2.dataDirectory)
        XCTAssertNotEqual(p1.dataDirectory, p3.dataDirectory)
        XCTAssertTrue(p1.dataDirectory.path.hasPrefix(tempDir.path), "data dirs must stay in the scratch root")
    }

    func testAddProfileRejectsEmptyName() {
        XCTAssertThrowsError(try manager.addProfile(named: "   ")) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidLabel)
        }
        XCTAssertEqual(manager.profiles.count, 0)
    }

    func testAddProfilePersistsImmediately() throws {
        let profile = try manager.addProfile(named: "Persisted")
        let reloaded = ProfileManager(store: manager.store, launcher: launcher, claudeBundleURL: manager.claudeBundleURL)
        reloaded.load()
        XCTAssertEqual(reloaded.profiles, [profile])
    }

    func testRenameProfile() throws {
        let profile = try manager.addProfile(named: "Before")
        try manager.renameProfile(id: profile.id, to: "After")
        XCTAssertEqual(manager.profiles.first?.label, "After")
        XCTAssertEqual(manager.profiles.first?.dataDirectory, profile.dataDirectory, "renaming must not move the data dir")
    }

    func testRenameProfileRejectsEmptyName() throws {
        let profile = try manager.addProfile(named: "Before")
        XCTAssertThrowsError(try manager.renameProfile(id: profile.id, to: " ")) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidLabel)
        }
        XCTAssertEqual(manager.profiles.first?.label, "Before")
    }

    func testRemoveProfileStopsItFirst() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Temp")
        try manager.start(id: profile.id)
        XCTAssertTrue(manager.isRunning(id: profile.id))

        try manager.removeProfile(id: profile.id)
        XCTAssertEqual(manager.profiles, [])
        XCTAssertFalse(manager.isRunning(id: profile.id))
        XCTAssertTrue(launcher.launchedHandles.last?.terminationRequested == true, "running profile must be stopped on removal")
    }

    func testRemoveProfileKeepsDataDirectoryOnDisk() throws {
        let profile = try manager.addProfile(named: "KeepMe")
        try FileManager.default.createDirectory(at: profile.dataDirectory, withIntermediateDirectories: true)
        try manager.removeProfile(id: profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
    }

    // MARK: Start

    func testStartFailsWithFriendlyErrorWhenBundleMissing() throws {
        let profile = try manager.addProfile(named: "X")
        XCTAssertThrowsError(try manager.start(id: profile.id)) { error in
            XCTAssertEqual(error as? ProfileManagerError,
                           .bundleMissing(path: tempDir.appendingPathComponent("Claude.app").path))
        }
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertFalse(manager.isRunning(id: profile.id))
    }

    func testStartLaunchesWithClaudeUserDataDirEnvironment() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Env Check")
        try manager.start(id: profile.id)

        XCTAssertTrue(manager.isRunning(id: profile.id))
        XCTAssertEqual(launcher.launches.count, 1)
        let record = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(record.executable.path,
                       tempDir.appendingPathComponent("Claude.app/Contents/MacOS/Claude").path)
        XCTAssertEqual(record.environment["CLAUDE_USER_DATA_DIR"], profile.dataDirectory.path)
    }

    func testStartCreatesDataDirectoryLazily() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Lazy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
        try manager.start(id: profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
    }

    func testStartIsIdempotentWhileRunning() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Once")
        try manager.start(id: profile.id)
        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testStartUnknownProfileThrows() {
        XCTAssertThrowsError(try manager.start(id: UUID())) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileNotFound)
        }
    }

    func testStartAfterExternalExitCanRestart() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Restart")
        try manager.start(id: profile.id)
        let handle = launcher.launchedHandles.first!

        handle.simulateExit()
        let expectation = expectation(description: "termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(manager.isRunning(id: profile.id))

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    func testQuickStopStartCannotLaunchDuplicateWhileOldProcessAlive() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Quick")
        try manager.start(id: profile.id)
        let first = try XCTUnwrap(launcher.launchedHandles.first)

        manager.stop(id: profile.id)
        XCTAssertFalse(manager.isRunning(id: profile.id), "stop reports stopped immediately")
        XCTAssertTrue(first.isRunning, "fake models the SIGTERM grace window: the old process is still alive")

        XCTAssertThrowsError(try manager.start(id: profile.id)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .stopInProgress)
        }
        XCTAssertEqual(launcher.launches.count, 1, "no duplicate may be launched into a data dir the old process still owns")

        first.simulateExit()
        let expectation = expectation(description: "termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2, "start works once the old process has actually exited")
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    func testStartReconcilesProcessThatExitedBeforeHandlerAssignment() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "FastExit")
        launcher.launchReturnsDeadHandle = true

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertFalse(manager.isRunning(id: profile.id),
                       "a process that died before the handler was attached must not stick as Running")

        launcher.launchReturnsDeadHandle = false
        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2, "the profile must be startable again")
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    // MARK: Stop

    func testStopMarksProfileStoppedAndTerminatesProcess() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "StopMe")
        try manager.start(id: profile.id)

        manager.stop(id: profile.id)
        XCTAssertFalse(manager.isRunning(id: profile.id), "stop must take effect immediately")
        XCTAssertTrue(launcher.launchedHandles.first?.terminationRequested == true)
    }

    func testStopOfStoppedProfileIsNoOp() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Idle")
        manager.stop(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 0)
    }

    // MARK: Relaunch reconciliation

    func testLoadMarksProfileRunningWhenLiveProcessOwnsItsDataDir() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Leftover")
        let leftover = FakeClaudeProcess(dataDirectory: profile.dataDirectory)
        launcher.runningHandlesToReturn = [leftover]

        let reloaded = makeManager()
        reloaded.load()

        XCTAssertTrue(reloaded.isRunning(id: profile.id),
                      "a leftover instance must show as running after relaunch")

        try reloaded.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 0,
                       "start must not spawn a duplicate into a data dir a live process owns")
        XCTAssertTrue(reloaded.isRunning(id: profile.id))

        reloaded.stop(id: profile.id)
        XCTAssertTrue(leftover.terminationRequested, "stop must terminate the leftover instance")

        leftover.simulateExit()
        let expectation = expectation(description: "leftover termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(reloaded.isRunning(id: profile.id), "state must clean up when the leftover exits")

        try reloaded.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1, "the profile must be startable again")
        XCTAssertTrue(reloaded.isRunning(id: profile.id))
    }

    func testLoadIgnoresLiveProcessesWithoutAMatchingProfile() throws {
        let profile = try manager.addProfile(named: "Only")
        let foreign = FakeClaudeProcess(dataDirectory: tempDir.appendingPathComponent("elsewhere"))
        launcher.runningHandlesToReturn = [foreign]

        let reloaded = makeManager()
        reloaded.load()

        XCTAssertFalse(reloaded.isRunning(id: profile.id),
                       "a process owning a different data dir must not mark the profile running")
        XCTAssertEqual(launcher.launches.count, 0)
    }

    // MARK: Persistence across instances

    func testProfilesSurviveManagerRecreation() throws {
        try manager.addProfile(named: "Alpha")
        try manager.addProfile(named: "Beta")

        let reloaded = makeManager()
        reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(reloaded.profiles, manager.profiles)
    }

    func testLoadReportsErrorOnCorruptStore() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("profiles.json").path,
                                       contents: Data("garbage".utf8))
        let corrupt = makeManager()
        corrupt.load()
        XCTAssertNotNil(corrupt.lastError)
        XCTAssertEqual(corrupt.profiles, [])
    }
}
