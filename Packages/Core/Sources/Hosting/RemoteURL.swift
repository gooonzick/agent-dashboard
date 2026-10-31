import Foundation

/// Where a repository lives on a hosting service: the host, and the path of the project on it.
///
/// It is read from the URL of a git remote, in any of the ways git writes one: `git@host:group/repo.git`,
/// `ssh://git@host:2222/group/repo.git`, `https://host/group/repo.git`. A remote that is no address on a hosting
/// service, such as a folder or a `file://` URL, is not one.
///
/// A remote may carry credentials: `https://user:token@host/group/repo`. They are dropped while reading. Nothing of
/// them is kept in a field of the value, so none can reach a log, a cache file or a request through it, and a URL
/// in which they could end up in a field is not read at all (see `projectPath`).
public struct RemoteURL: Sendable, Equatable, Hashable, Codable {
    /// The host, in lowercase: a host name is not case sensitive, and two spellings of one are one host.
    public let host: String
    /// The port that the URL names, if it does. For `ssh://` that is the port of SSH, and not the one of the web
    /// interface of the host.
    public let port: Int?
    /// The path of the project on the host, `group/sub/repo`: without `.git`, and without a slash at either end.
    ///
    /// It has at least two names, as a project of GitHub or GitLab has an owner or a group, and every name is made
    /// of the letters, digits, `.`, `_` and `-` that those services allow in one. A path that holds more than that,
    /// such as the `@` or `?` of a credential or of a query, is none that either service would have.
    public let projectPath: String

    /// The schemes in which git reaches a hosting service. (`git+ssh` and `ssh+git` are old names of `ssh`.)
    private static let schemes: Set<String> = ["ssh", "git", "http", "https", "git+ssh", "ssh+git"]

    public init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let (authority, path) = Self.split(text),
            let (host, port) = Self.hostAndPort(of: authority),
            let projectPath = Self.projectPath(of: path)
        else { return nil }
        self.host = host
        self.port = port
        self.projectPath = projectPath
    }

    // MARK: Reading

    /// The part of `text` that names the host, `[user@]host[:port]`, and the part that names the project.
    ///
    /// git tells the two forms apart as this does: a URL has a scheme in front of `://`, and anything else that has a
    /// colon before its first slash is `scp`-like, `[user@]host:path`.
    private static func split(_ text: String) -> (authority: Substring, path: Substring)? {
        if let separator = text.range(of: "://"), isScheme(text[..<separator.lowerBound]) {
            guard schemes.contains(text[..<separator.lowerBound].lowercased()) else { return nil }
            let rest = text[separator.upperBound...]
            let end = rest.firstIndex(of: "/") ?? rest.endIndex
            return (rest[..<end], rest[end...])
        }
        guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") else { return nil }
        return (text[..<colon], text[text.index(after: colon)...])
    }

    /// The host and port of `authority`, with the user, the password and any token in front of them dropped.
    private static func hostAndPort(of authority: Substring) -> (host: String, port: Int?)? {
        // The user is everything up to the last `@`: a password may hold an `@` that was not escaped, and the host is
        // what comes after all of it. Nothing of the user is looked at or kept.
        let hostAndPort = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        guard let colon = hostAndPort.lastIndex(of: ":") else {
            return isValidHost(hostAndPort) ? (hostAndPort.lowercased(), nil) : nil
        }
        let host = hostAndPort[..<colon]
        let digits = hostAndPort[hostAndPort.index(after: colon)...]
        guard isValidHost(host) else { return nil }
        // `host:` with no port is how a URL says "the usual port".
        guard !digits.isEmpty else { return (host.lowercased(), nil) }
        guard digits.allSatisfy(isDigit), let port = Int(digits), (1...65535).contains(port) else { return nil }
        return (host.lowercased(), port)
    }

    /// `path` without `.git` at its end and without the slashes at its ends, or `nil` if it is no project path.
    private static func projectPath(of path: Substring) -> String? {
        var names = path.split(separator: "/")  // a leading, trailing or doubled slash leaves no empty name
        guard let last = names.popLast() else { return nil }
        names.append(last.hasSuffix(".git") ? last.dropLast(".git".count) : last)
        guard names.count >= 2, names.allSatisfy(isProjectName) else { return nil }
        return names.joined(separator: "/")
    }

    // MARK: What is valid

    /// Whether `host` can stand in `https://<host>/` without changing what the address means: dot-separated names of
    /// ASCII letters, digits, `-` and `_`, none empty and none starting or ending with `-`. IPv4 addresses are hosts
    /// by this. IPv6 addresses are not, and neither are names with other characters than ASCII.
    ///
    /// Everything that puts a host into a URL or hands it to another program checks this first: a host is data of a
    /// repository that is found on the disk, and what it holds is nobody's to trust.
    static func isValidHost(_ host: some StringProtocol) -> Bool {
        !host.isEmpty
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy(isHostCharacter)
            }
    }

    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.first, isLetter(first) else { return false }
        return text.allSatisfy { isLetter($0) || isDigit($0) || "+-.".contains($0) }
    }

    private static func isProjectName(_ name: Substring) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.allSatisfy { isLetter($0) || isDigit($0) || "._-".contains($0) }
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        isLetter(character) || isDigit(character) || "-_".contains(character)
    }

    // `Character.isLetter` and `isNumber` are true of letters and numbers of every script, so ASCII is asked for first.

    private static func isLetter(_ character: Character) -> Bool { character.isASCII && character.isLetter }

    private static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
}
