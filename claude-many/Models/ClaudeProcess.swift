import Foundation

/// Handle to a running Claude instance, abstracted behind a protocol so unit
/// tests can verify state transitions without launching the real app.
protocol ClaudeProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Called (on an arbitrary queue) when the process exits on its own.
    var terminationHandler: (@Sendable () -> Void)? { get set }
    /// Ask the process to exit cleanly (SIGTERM).
    func terminate()
    /// Kill the process outright (SIGKILL).
    func terminateForcefully()
}

/// Spawns `Process` instances. Injected into `ProfileManager`; tests replace
/// this with a fake that records launches.
protocol ClaudeLauncher: Sendable {
    func launch(executable: URL, environment: [String: String]) throws -> ClaudeProcessHandle
}

/// Real launcher backed by Foundation's `Process`.
struct RealClaudeLauncher: ClaudeLauncher {
    func launch(executable: URL, environment: [String: String]) throws -> ClaudeProcessHandle {
        let process = Process()
        process.executableURL = executable

        // Foundation's Process inherits the parent environment when left nil,
        // but replacing it wholesale with a merged copy is more predictable
        // (keeps PATH etc. while adding CLAUDE_USER_DATA_DIR).
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        // Claude's output is not ours; keep it off the console.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        return RealClaudeProcess(process: process)
    }
}

/// Wraps a Foundation `Process`. Only touched from the main actor in practice;
/// the termination callback is the sole cross-thread surface, and it is
/// designed to hop back to the main actor before touching app state.
final class RealClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    private let process: Process
    private var storedTerminationHandler: (@Sendable () -> Void)?

    init(process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    var terminationHandler: (@Sendable () -> Void)? {
        get { storedTerminationHandler }
        set {
            storedTerminationHandler = newValue
            process.terminationHandler = { [weak self] _ in
                self?.storedTerminationHandler?()
            }
        }
    }

    func terminate() {
        process.terminate() // SIGTERM; Electron apps shut down gracefully
    }

    func terminateForcefully() {
        kill(process.processIdentifier, SIGKILL)
    }
}
