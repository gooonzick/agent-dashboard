import Foundation

/// An image of the Docker VM.
public struct DockerImage: Sendable, Equatable, Identifiable {
    public let id: String
    /// `repository:tag`, or the ID of an image that has no name.
    public let name: String
    public let size: UInt64
    /// No container, running or stopped, was made from it, so `docker image prune -a` removes it.
    public let isUnused: Bool
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
}

/// What a Docker VM holds, as far as the page shows it.
public struct DockerInventory: Sendable, Equatable {
    public let images: [DockerImage]
    public let containers: [DockerContainer]
    public let volumesSize: UInt64
    public let buildCacheSize: UInt64
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
        let images = lines(images).map { image($0, usedBy: containers) }
        let sizes = Dictionary(
            lines(usage).compactMap { row in
                (row["Type"] as? String).map { ($0, DockerSize.bytes(row["Size"] as? String ?? "") ?? 0) }
            }, uniquingKeysWith: { first, _ in first })
        return DockerInventory(
            images: images, containers: containers, volumesSize: sizes["Local Volumes"] ?? 0,
            buildCacheSize: sizes["Build Cache"] ?? 0)
    }

    private static func image(_ row: [String: Any], usedBy containers: [DockerContainer]) -> DockerImage {
        let id = shortID(row["ID"] as? String ?? "")
        let repository = row["Repository"] as? String ?? ""
        let tag = row["Tag"] as? String ?? ""
        let name = repository == "<none>" ? id : tag == "<none>" ? repository : "\(repository):\(tag)"
        // A container names its image by `repository:tag`, by the repository alone (which means `latest`) or by ID,
        // so the `Containers` column, which is `N/A` here, is not asked.
        let names: Set<String> = [name, tag == "latest" ? repository : "", id]
        let isUsed = containers.contains { names.contains($0.image) || shortID($0.image) == id }
        return DockerImage(
            id: id, name: name, size: DockerSize.bytes(row["Size"] as? String ?? "") ?? 0, isUnused: !isUsed)
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
