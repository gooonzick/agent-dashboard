import CoreServices
import Foundation

/// Tells when something changes in the file system.
public protocol FileWatching: Sendable {
    /// Calls `onChange` with the paths of the folders in which something changed, below any of `paths`, from now on.
    /// Changes that come within `latency` of each other are reported together. `onChange` is called on a queue of the
    /// watcher, never on the main thread.
    ///
    /// The watching goes on for as long as the returned token is kept, and stops when it is released.
    func watch(paths: [String], latency: Duration, onChange: @escaping @Sendable ([String]) -> Void) -> AnyObject
}

/// Watches folders with FSEvents.
///
/// The events are those of folders: a file that is written is reported as the folder that holds it. That keeps the
/// number of events down where a build writes thousands of files, and it is all the dashboard asks: which worktree
/// changed, and whether a `.git` folder appeared or went away (its folder, or something inside it, is reported).
/// Paths come canonical, as the kernel has them, without a trailing slash.
public struct FileWatcher: FileWatching {
    public init() {}

    public func watch(
        paths: [String], latency: Duration, onChange: @escaping @Sendable ([String]) -> Void
    ) -> AnyObject {
        EventStream(paths: paths, latency: latency, onChange: onChange)
    }
}

/// One FSEvents stream. It runs from `init` until it is released.
private final class EventStream {
    /// What the stream calls. The stream keeps it through its context, which retains it.
    private final class Receiver {
        let onChange: @Sendable ([String]) -> Void
        init(_ onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
    }

    private static let queue = DispatchQueue(label: "dev.gooonzick.AgentDashboard.FileWatcher", qos: .utility)

    private let stream: FSEventStreamRef?

    init(paths: [String], latency: Duration, onChange: @escaping @Sendable ([String]) -> Void) {
        let receiver = Unmanaged.passRetained(Receiver(onChange))
        var context = FSEventStreamContext(
            version: 0, info: receiver.toOpaque(),
            retain: nil,
            release: { info in info.map { Unmanaged<Receiver>.fromOpaque($0).release() } },
            copyDescription: nil)
        let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), seconds, flags)
        guard let stream else {
            receiver.release()  // no stream took it
            return
        }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)  // releases the context, and with it the receiver
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes the paths are a CFArray of CFStrings.
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        let changed = (0..<min(count, array.count)).compactMap { array[$0] as? String }.map { path in
            var path = Substring(path)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return String(path)
        }
        if !changed.isEmpty { receiver.onChange(changed) }
    }
}
