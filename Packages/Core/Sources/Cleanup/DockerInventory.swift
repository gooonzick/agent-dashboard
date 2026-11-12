import Foundation

/// An image of the Docker VM.
public struct DockerImage: Sendable, Equatable, Identifiable {
    public let id: String
    /// `repository:tag`, or the ID of an image that has no name.
    public let name: String
    public let size: UInt64
    /// No container, running or stopped, was made from it, so `docker image prune -a` removes it.
    public let isUnused: Bool

    public init(id: String, name: String, size: UInt64, isUnused: Bool) {
        self.id = id
        self.name = name
        self.size = size
        self.isUnused = isUnused
    }
}

/// A container of the Docker VM, running or not.
public struct DockerContainer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let isRunning: Bool
    /// What the container wrote on top of its image.
    public let size: UInt64
    /// The folder of the compose project that made the container, from its `working_dir` label.
    public let project: String?

    public init(id: String, name: String, image: String, isRunning: Bool, size: UInt64, project: String?) {
        self.id = id
        self.name = name
        self.image = image
        self.isRunning = isRunning
        self.size = size
        self.project = project
    }
}

/// What a Docker VM holds, as far as the page shows it.
public struct DockerInventory: Sendable, Equatable {
    public let images: [DockerImage]
    public let containers: [DockerContainer]
    public let volumesSize: UInt64
    public let buildCacheSize: UInt64

    public init(images: [DockerImage], containers: [DockerContainer], volumesSize: UInt64, buildCacheSize: UInt64) {
        self.images = images
        self.containers = containers
        self.volumesSize = volumesSize
        self.buildCacheSize = buildCacheSize
    }
}

/// The sizes the Docker CLI prints (`5.393GB`, `719MB`, `24.58kB`).
public enum DockerSize {
    /// Docker counts in decimal units: a kB is 1000 bytes. `nil` for text that is not a size, such as `N/A`.
    public static func bytes(_ text: String) -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let number = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(number.count).lowercased()
        let factors: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15]
        guard let value = Double(number), let factor = factors[unit] else { return nil }
        return UInt64((value * factor).rounded())
    }
}

/// Reads the JSON lines that `docker ... --format json` prints, and decides what is unused.
enum DockerParsers {
    static let projectLabel = "com.docker.compose.project.working_dir"

    static func lines(_ output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    static func inventory(images: String, containers: String, usage: String) -> DockerInventory {
        let containers = lines(containers).map(container)
        let rows = lines(images).map(image)
        // Docker keeps one image per ID however many tags it has, and `image prune -a` keeps all of them while any
        // container runs from one of the tags, so use is decided per ID.
        let used = rows.filter { row in containers.contains { uses($0.image, row) } }
        let usedIDs = Set(used.map(\.image.id))
        let images = rows.map { row in
            DockerImage(
                id: row.image.id, name: row.image.name, size: row.image.size,
                isUnused: !usedIDs.contains(row.image.id))
        }
        let sizes = Dictionary(
            lines(usage).compactMap { row in
                (row["Type"] as? String).map { ($0, DockerSize.bytes(row["Size"] as? String ?? "") ?? 0) }
            }, uniquingKeysWith: { first, _ in first })
        return DockerInventory(
            images: images, containers: containers, volumesSize: sizes["Local Volumes"] ?? 0,
            buildCacheSize: sizes["Build Cache"] ?? 0)
    }

    /// Whether a container whose image is `reference` runs from `row`. A container started from an image pinned by
    /// digest names it `repository@sha256:…` or `repository:tag@sha256:…`. That digest is the registry's, not the ID,
    /// and the image may be listed under any tag of the repository, so without a tag every image of the repository
    /// counts as used: one shown as unused that is not would be the worse mistake.
    private static func uses(_ reference: String, _ row: ImageRow) -> Bool {
        if row.names.contains(reference) || shortID(reference) == row.image.id { return true }
        let parts = reference.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if row.digest == parts[1] { return true }
        // A colon after the last slash starts the tag; one before it ends the port of a registry.
        let hasTag = parts[0].split(separator: "/").last?.contains(":") == true
        return hasTag ? row.names.contains(parts[0]) : row.repository == parts[0]
    }

    /// An image as `docker image ls` lists it, and what a container may call it by.
    private struct ImageRow {
        let image: DockerImage
        let repository: String
        /// `repository:tag`, the bare repository (which means `latest`, or that the image has no tag) and the ID.
        let names: Set<String>
        /// The registry digest, when Docker lists one.
        let digest: String?
    }

    private static func image(_ row: [String: Any]) -> ImageRow {
        let id = shortID(row["ID"] as? String ?? "")
        let repository = row["Repository"] as? String ?? ""
        let tag = row["Tag"] as? String ?? ""
        let name = repository == "<none>" ? id : tag == "<none>" ? repository : "\(repository):\(tag)"
        let image = DockerImage(
            id: id, name: name, size: DockerSize.bytes(row["Size"] as? String ?? "") ?? 0, isUnused: true)
        return ImageRow(
            image: image, repository: repository, names: Set([name, id] + (tag == "latest" ? [repository] : [])),
            digest: (row["Digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? $0 : nil })
    }

    private static func container(_ row: [String: Any]) -> DockerContainer {
        let labels = (row["Labels"] as? String ?? "").split(separator: ",")
        let prefix = projectLabel + "="
        let project = labels.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        // `24.6kB (virtual 1.1GB)`: the first number is what the container wrote, the second counts its image too.
        let written = (row["Size"] as? String ?? "").components(separatedBy: " (").first ?? ""
        let names = (row["Names"] as? String ?? "").split(separator: ",")
        return DockerContainer(
            id: row["ID"] as? String ?? "", name: names.first.map(String.init) ?? "",
            image: row["Image"] as? String ?? "", isRunning: row["State"] as? String == "running",
            size: DockerSize.bytes(written) ?? 0, project: project)
    }

    /// The 12 characters Docker shows of an image ID, without the `sha256:` that newer versions put in front.
    private static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
}
