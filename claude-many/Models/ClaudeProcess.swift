import Foundation

/// Handle to a running Claude instance, abstracted behind a protocol so unit
/// tests can verify state transitions without launching the real app.
protocol ClaudeProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// The data directory this process runs with (CLAUDE_USER_DATA_DIR), when known.
    var dataDirectory: URL? { get }
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
    /// Live handles for processes running `executable` with CLAUDE_USER_DATA_DIR set.
    func runningHandles(executable: URL) -> [ClaudeProcessHandle]
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
        return RealClaudeProcess(
            process: process,
            dataDirectory: environment["CLAUDE_USER_DATA_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        )
    }

    /// Discovers live processes running `executable` whose environment carries
    /// `CLAUDE_USER_DATA_DIR`, so the manager can adopt instances left over
    /// from a previous app run. macOS exposes the environment for app
    /// processes (but not CLI tools), which is exactly the population matched.
    func runningHandles(executable: URL) -> [ClaudeProcessHandle] {
        let target = executable.resolvingSymlinksInPath().path
        var result: [ClaudeProcessHandle] = []
        for (pid, startTime) in Self.allProcesses() {
            guard let info = Self.processInfo(for: pid),
                  Self.executableMatches(info.executablePath, target: target),
                  let dataDir = info.environment["CLAUDE_USER_DATA_DIR"] else {
                continue
            }
            result.append(AttachedClaudeProcess(
                pid: pid,
                startTime: startTime,
                dataDirectory: URL(fileURLWithPath: dataDir, isDirectory: true)
            ))
        }
        return result
    }

    // MARK: Process introspection

    private struct ProcessSnapshot {
        let executablePath: String
        let environment: [String: String]
    }

    private static func allProcesses() -> [(pid: Int32, startTime: timeval)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.size
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.map { ($0.kp_proc.p_pid, $0.kp_proc.p_un.__p_starttime) }
    }

    /// The kernel-reported start time of a PID, or nil if no such process
    /// exists. Together with the PID it uniquely identifies a process instance.
    static func processStartTime(for pid: Int32) -> timeval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        var proc = kinfo_proc()
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0,
              size > 0 else { return nil }
        return proc.kp_proc.p_un.__p_starttime
    }

    /// Reads a process's executable path and environment via KERN_PROCARGS2.
    private static func processInfo(for pid: Int32) -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        guard let execEnd = buffer[index...].firstIndex(of: 0) else { return nil }
        let executablePath = String(decoding: buffer[index..<execEnd], as: UTF8.self)
        index = execEnd + 1
        while index < buffer.count && buffer[index] == 0 { index += 1 }

        var argumentCount = 0
        while index < buffer.count && argumentCount < argc {
            guard let end = buffer[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
            argumentCount += 1
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            guard let end = buffer[index...].firstIndex(of: 0) else { break }
            if end == index { break }
            let entry = String(decoding: buffer[index..<end], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index = end + 1
        }
        return ProcessSnapshot(executablePath: executablePath, environment: environment)
    }

    /// The kernel appends " (deleted)" to the path of a binary that was
    /// replaced on disk while running (e.g. a Claude auto-update).
    private static func executableMatches(_ path: String, target: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved == target { return true }
        return resolved.hasPrefix(target) && resolved.hasSuffix(" (deleted)")
    }
}

/// Wraps a Foundation `Process`. Only touched from the main actor in practice;
/// the termination callback is the sole cross-thread surface, and it is
/// designed to hop back to the main actor before touching app state.
final class RealClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    private let process: Process
    let dataDirectory: URL?
    private var storedTerminationHandler: (@Sendable () -> Void)?

    init(process: Process, dataDirectory: URL? = nil) {
        self.process = process
        self.dataDirectory = dataDirectory
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

/// Handle for a Claude instance that was discovered on the system rather than
/// spawned by this app run (e.g. left over from before a relaunch). There is
/// no Foundation `Process` to observe, so termination is detected by polling.
final class AttachedClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32
    let dataDirectory: URL?
    /// The process's kernel start time, captured at adoption. The PID plus
    /// this value identify one specific process instance even if the OS
    /// recycles PIDs, so a later unrelated process can never be mistaken for
    /// (or signaled as) the adopted one.
    private let startTime: timeval
    private var storedTerminationHandler: (@Sendable () -> Void)?
    private var monitorTask: Task<Void, Never>?

    init(pid: Int32, startTime: timeval, dataDirectory: URL?) {
        self.processIdentifier = pid
        self.startTime = startTime
        self.dataDirectory = dataDirectory
    }

    /// True only while the PID still refers to the adopted process instance.
    private var sameProcessExists: Bool {
        guard let current = RealClaudeLauncher.processStartTime(for: processIdentifier) else {
            return false
        }
        return current.tv_sec == startTime.tv_sec && current.tv_usec == startTime.tv_usec
    }

    var isRunning: Bool {
        guard sameProcessExists else { return false }
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    var terminationHandler: (@Sendable () -> Void)? {
        get { storedTerminationHandler }
        set {
            storedTerminationHandler = newValue
            if newValue != nil {
                startMonitoring()
            } else {
                monitorTask?.cancel()
                monitorTask = nil
            }
        }
    }

    func terminate() {
        guard sameProcessExists else { return }
        kill(processIdentifier, SIGTERM)
    }

    func terminateForcefully() {
        guard sameProcessExists else { return }
        kill(processIdentifier, SIGKILL)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !self.isRunning {
                    self.storedTerminationHandler?()
                    return
                }
            }
        }
    }
}
