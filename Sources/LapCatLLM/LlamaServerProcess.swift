import Darwin
import Foundation
import os

/// A running `llama-server`, spawned in its own process group under a `/bin/sh` watchdog that
/// kills the server within a second of this process disappearing (including SIGKILL/crash).
/// Normal exit paths terminate the whole group: `terminate()`, the owner's deinit, and `atexit`.
final class LlamaServerProcess: Sendable {
    let pid: pid_t
    let port: Int
    private let exited = OSAllocatedUnfairLock(initialState: false)
    private let stderrTail = OSAllocatedUnfairLock(initialState: Data())
    private let exitSource: any DispatchSourceProcess
    private let stderrHandle: FileHandle

    private static let logger = Logger(subsystem: "com.lapcat.app", category: "LlamaServerProvider")
    private static let live = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    private static let installExitHook: Void = {
        atexit {
            for pid in LlamaServerProcess.live.withLock({ $0 }) { kill(-pid, SIGTERM) }
        }
    }()

    /// Runs `"$0" "$@"` (llama-server and its args) in the background and exits with it, or kills it
    /// once `LAPCAT_PARENT_PID` is gone.
    private static let watchdog = """
        "$0" "$@" & child=$!
        trap 'kill -TERM $child 2>/dev/null; wait $child; exit 0' TERM INT HUP
        while kill -0 "$LAPCAT_PARENT_PID" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
        kill -TERM $child 2>/dev/null
        wait $child
        """

    init(binary: URL, arguments: [String], port: Int) throws {
        _ = Self.installExitHook
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw LLMError.unavailable("pipe failed: errno \(errno)") }
        let (readFD, writeFD) = (fds[0], fds[1])
        defer { close(writeFD) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (pgid = pid) so one kill(-pid) reaches the shell and the server;
        // CLOEXEC_DEFAULT keeps every other descriptor of ours out of the child. The signal mask and
        // dispositions are reset because the spawning (dispatch) thread blocks SIGTERM, which the
        // child would otherwise inherit and never die from.
        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] { sigaddset(&defaultSignals, signal) }
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var environment = ProcessInfo.processInfo.environment
        environment["LAPCAT_PARENT_PID"] = String(getpid())
        let argv = ["/bin/sh", "-c", Self.watchdog, binary.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/sh", &actions, &attr, &cArgv, &cEnvp)
        guard status == 0 else {
            close(readFD)
            throw LLMError.unavailable("could not launch llama-server: \(String(cString: strerror(status)))")
        }
        let pid = spawned
        self.pid = pid
        self.port = port
        Self.live.withLock { _ = $0.insert(pid) }

        stderrHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        self.exitSource = exitSource
        let tail = stderrTail
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.withLock { buffer in
                buffer.append(data)
                if buffer.count > 8192 { buffer.removeFirst(buffer.count - 8192) }
            }
        }
        let exited = exited
        exitSource.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            exited.withLock { $0 = true }
            Self.live.withLock { _ = $0.remove(pid) }
            exitSource.cancel()
        }
        exitSource.resume()
        // The child may have exited before the source was armed.
        if waitpid(pid, nil, WNOHANG) == pid {
            exited.withLock { $0 = true }
            Self.live.withLock { _ = $0.remove(pid) }
            exitSource.cancel()
        }
        Self.logger.info("llama-server started (pid \(pid), port \(port))")
    }

    var isRunning: Bool { !exited.withLock { $0 } }

    /// The last non-empty stderr line, used in launch-failure messages.
    var lastErrorLine: String {
        let text = String(decoding: stderrTail.withLock { $0 }, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no output"
    }

    /// SIGTERM to the group, SIGKILL after 3 s if anything survives.
    func terminate() {
        guard isRunning else { return }
        Self.logger.info("stopping llama-server (pid \(self.pid))")
        let pid = pid
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
    }

    /// An unused TCP port on 127.0.0.1, found by binding port 0.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLMError.unavailable("socket failed: errno \(errno)") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(fd, address, length) == 0 && getsockname(fd, address, &length) == 0
            }
        }
        guard bound else { throw LLMError.unavailable("no free port: errno \(errno)") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
