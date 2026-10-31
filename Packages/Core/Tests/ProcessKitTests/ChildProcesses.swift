import Darwin
import Foundation

// Children of the test that `Foundation.Process` cannot make: one that inherits a given descriptor, and one that has
// exited but has not been collected.

extension POSIXError {
    /// The error for an `errno` value, or `EIO` for one that has no `POSIXErrorCode`.
    init(errno code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Runs `body` with the id of a child that runs `executable` and has the descriptors in `inheriting`, and no others.
/// `argv0` is what the child is told that it was called, which `Process` does not let one choose: the path of the
/// executable if it is not given.
///
/// A plain `posix_spawn` child gets every descriptor of the test that is not marked close-on-exec, those of the tests
/// that run beside this one included, and it would hold a pipe of another test open. The child is killed, and
/// collected, when `body` is done.
func withChild<T>(
    _ executable: String, _ arguments: [String], argv0: String? = nil, inheriting descriptors: [Int32] = [],
    _ body: (pid_t) throws -> T
) throws -> T {
    let pid = try startChild(executable, arguments, argv0: argv0, inheriting: descriptors)
    defer {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
    return try body(pid)
}

/// Runs `body` with the id of a zombie: a child that has exited and that nobody has waited for yet, which is all the
/// system keeps of it. It is collected when `body` is done.
func withZombie<T>(_ body: (pid_t) throws -> T) throws -> T {
    let pid = try startChild("/usr/bin/true", [], argv0: nil, inheriting: [])
    defer {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
    // WNOWAIT leaves the child as it is, a zombie. The wait ends when it has exited.
    var info = siginfo_t()
    guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else { throw POSIXError(errno: errno) }
    return try body(pid)
}

private func startChild(
    _ executable: String, _ arguments: [String], argv0: String?, inheriting descriptors: [Int32]
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    // Every descriptor is closed in the child, except for those that are named.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    for descriptor in descriptors { posix_spawn_file_actions_addinherit_np(&actions, descriptor) }

    let argv = ([argv0 ?? executable] + arguments).map { strdup($0) } + [nil]
    defer {
        for argument in argv { free(argument) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, [nil])
    guard status == 0 else { throw POSIXError(errno: status) }
    return pid
}
