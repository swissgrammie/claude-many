import XCTest
import AppKit
import CoreGraphics
@testable import claude_many

/// Live smoke test: launches TWO real Claude Desktop instances against two
/// scratch data directories and verifies the isolation mechanism end to end
/// (two processes, two windows, two independently populated data dirs), then
/// stops both and verifies clean termination.
///
/// Gated behind `CLAUDE_MANY_SMOKE=1` so the ordinary test run never spawns
/// real applications. Scratch state lives under a throwaway /tmp directory
/// and is removed afterwards; the captain's real profile is never touched.
@MainActor
final class SmokeTests: XCTestCase {
    /// Gate: the live smoke test launches real Claude instances, so it must be
    /// opted into. xcodebuild does not reliably pass environment variables to
    /// hosted test processes, so the gate is a flag file: `touch
    /// /tmp/claude-many-smoke-run` before running the tests. The flag is
    /// removed after the whole class finishes, so an ordinary later test run
    /// never launches real applications.
    nonisolated private static let gateFlag = "/tmp/claude-many-smoke-run"

    nonisolated override class func tearDown() {
        try? FileManager.default.removeItem(atPath: gateFlag)
        super.tearDown()
    }

    func testSmokeTwoIsolatedInstances() throws {
        let envGate = ProcessInfo.processInfo.environment["CLAUDE_MANY_SMOKE"] == "1"
        try XCTSkipUnless(
            envGate || FileManager.default.fileExists(atPath: Self.gateFlag),
            "Opt in with CLAUDE_MANY_SMOKE=1 or `touch /tmp/claude-many-smoke-run` (launches real Claude instances)."
        )

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-many-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: RealClaudeLauncher(),
            claudeBundleURL: ProfileManager.defaultBundleURL,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
        XCTAssertTrue(manager.bundleExists, "Claude.app must be installed for the smoke test")

        // Two profiles with distinct scratch data dirs.
        let p1 = try manager.addProfile(named: "Smoke One")
        let p2 = try manager.addProfile(named: "Smoke Two")
        XCTAssertNotEqual(p1.dataDirectory, p2.dataDirectory)
        XCTAssertTrue(p1.dataDirectory.path.hasPrefix(root.path))

        // Baseline: other Claude instances (e.g. the user's own) may already
        // be running; we only count the ones this test adds.
        let baselineProcesses = claudeProcessCount()
        let baselineWindows = claudeWindowCount()

        // Start both.
        try manager.start(id: p1.id)
        try manager.start(id: p2.id)
        XCTAssertTrue(waitFor(timeout: 20) {
            manager.isRunning(id: p1.id) && manager.isRunning(id: p2.id)
        }, "both instances should be running")

        // Claude writes its own layout into each fresh data dir.
        XCTAssertTrue(waitFor(timeout: 180) {
            self.isPopulated(p1.dataDirectory) && self.isPopulated(p2.dataDirectory)
        }, "Claude did not populate both profile data directories")

        // Exactly the two new processes appeared, each with Claude's bundle id.
        XCTAssertTrue(waitFor(timeout: 60) {
            claudeProcessCount() >= baselineProcesses + 2
        }, "expected 2 additional running Claude Desktop processes")
        XCTAssertEqual(claudeProcessCount() - baselineProcesses, 2,
                       "exactly two new Claude instances should be running")

        // ... and two separate windows, one per instance.
        XCTAssertTrue(waitFor(timeout: 60) {
            claudeWindowCount() >= baselineWindows + 2
        }, "expected 2 additional Claude windows")
        XCTAssertEqual(claudeWindowCount() - baselineWindows, 2,
                       "exactly two new Claude windows should be on screen")

        // Stop both; expect clean termination (delta back to baseline).
        manager.stop(id: p1.id)
        manager.stop(id: p2.id)
        XCTAssertTrue(waitFor(timeout: 30) {
            !manager.isRunning(id: p1.id) && !manager.isRunning(id: p2.id)
        }, "both instances should stop cleanly")
        XCTAssertTrue(waitFor(timeout: 30) {
            claudeProcessCount() <= baselineProcesses
        }, "the two smoke instances should have exited")

        // defer removes the scratch dir; nothing leaks into ~/Library.
    }

    /// Verifies the relaunch-reconciliation path end to end: quit the app
    /// without stopping, relaunch, the leftover instance is detected by its
    /// data dir and shown as running, Start refuses to spawn a duplicate, and
    /// Stop terminates the leftover. Gated like the main smoke test.
    func testSmokeReconcilesLeftoverInstancesAfterRelaunch() throws {
        let envGate = ProcessInfo.processInfo.environment["CLAUDE_MANY_SMOKE"] == "1"
        try XCTSkipUnless(
            envGate || FileManager.default.fileExists(atPath: Self.gateFlag),
            "Opt in with CLAUDE_MANY_SMOKE=1 or `touch /tmp/claude-many-smoke-run` (launches real Claude instances)."
        )

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("claude-many-smoke-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let store = ProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
        let dataRoot = root.appendingPathComponent("Profiles")
        let makeManager = {
            ProfileManager(
                store: store,
                launcher: RealClaudeLauncher(),
                claudeBundleURL: ProfileManager.defaultBundleURL,
                dataRootDirectory: dataRoot
            )
        }
        let manager = makeManager()
        XCTAssertTrue(manager.bundleExists, "Claude.app must be installed for the smoke test")

        let profile = try manager.addProfile(named: "Reconcile One")
        try manager.start(id: profile.id)
        XCTAssertTrue(waitFor(timeout: 20) { manager.isRunning(id: profile.id) })
        XCTAssertTrue(waitFor(timeout: 180) { self.isPopulated(profile.dataDirectory) })

        let baselineProcesses = claudeProcessCount()

        // Simulate an app relaunch: a brand-new manager over the same store
        // and data root, as if the user quit claude-many without stopping.
        let relaunched = makeManager()
        relaunched.load()
        XCTAssertTrue(relaunched.isRunning(id: profile.id),
                      "the leftover instance must be reconciled as running after relaunch")

        // Start must not spawn a second instance into the live data dir.
        try relaunched.start(id: profile.id)
        XCTAssertTrue(waitFor(timeout: 60) {
            claudeProcessCount() <= baselineProcesses
        }, "no additional Claude process may be spawned while the leftover owns the data dir")

        // Stopping via the relaunched manager terminates the leftover.
        relaunched.stop(id: profile.id)
        XCTAssertTrue(waitFor(timeout: 30) {
            !relaunched.isRunning(id: profile.id) && claudeProcessCount() <= baselineProcesses - 1
        }, "stopping the reconciled instance must terminate the leftover process")
    }

    // MARK: Helpers

    private func claudeProcessCount() -> Int {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
            .count
    }

    private func claudeWindowCount() -> Int {
        let claudePids = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }
                .map(\.processIdentifier)
        )
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        return windows.filter { win in
            guard let pid = win[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return claudePids.contains(pid)
        }.count
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return condition()
    }

    private func isPopulated(_ dir: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return contents.count >= 3
    }
}
