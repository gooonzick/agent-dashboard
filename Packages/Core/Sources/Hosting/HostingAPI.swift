import Foundation

/// The access token of a host, as a client keeps it. It shows as nothing wherever a value is shown, in a description,
/// a dump or a log, so that to hold one in a field of a client is not to put it in any of them.
struct AccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    /// The token as it is put in a header, or `nil` if there is none: an empty token is none. Anything else has to be
    /// one word of printable ASCII, as the token of a service is: a token with a line break in it would put a header of
    /// its own in.
    func headerValue() throws -> String? {
        guard !text.isEmpty else { return nil }
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw ReviewError.unusableToken
        }
        return text
    }

    var description: String { "AccessToken" }
    var debugDescription: String { "AccessToken" }
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// What `GitLabClient` and `GitHubClient` have in common: how an address is written, how a request is sent and its
/// answer is told apart from an error, and how the fields that both services have are checked.
///
/// A host is not to be trusted: it may be anybody's. So the answer of one is read for what is needed and no more, and a
/// field that decides something, or is handed on to another program, is checked before it is used.
enum HostingAPI {
    /// How long a host gets to answer one request. The default of a request is a minute.
    static let timeout: TimeInterval = 20

    // MARK: Whom a client may ask, and about what

    /// Throws unless `remote` is on `host`, the host that the client was made for, and has a branch.
    ///
    /// The token of a client is the token of its host, and the project that a remote names is one of the host of the
    /// remote: neither goes to another host. A branch with no name is not asked about either, since a host answers a
    /// search for it with the requests of all branches.
    static func check(_ remote: RemoteURL, on host: String, branch: String) throws {
        guard RemoteURL.isValidHost(host), remote.host == host else { throw ReviewError.otherHost }
        guard !branch.isEmpty else { throw ReviewError.noBranch }
    }

    // MARK: Addresses

    /// `text` as one part of an address: all that is not a letter, a digit, `-`, `.`, `_` or `~` is written in percent
    /// escapes, as the bytes of its UTF-8. So `/` is `%2F`, and neither `+`, `&`, `=` nor `#` can be taken for what
    /// each means in a query.
    static func encode(_ text: String) -> String {
        var encoded = ""
        for byte in text.utf8 {
            if isUnreserved(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// The `https` address of `path` on `host`, with `query` after it. `path` and the names and values of `query` are
    /// written in percent escapes already (see `encode`), and they are put into the address as they are.
    ///
    /// It has no port: the usual one of HTTPS. The port that a remote names is never used for a request, since it is
    /// mostly the port of SSH, which the web interface does not have, and `RemoteURL` does not keep the scheme that
    /// would tell the two apart.
    static func url(host: String, path: String, query: [(name: String, value: String)]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.percentEncodedQueryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        // A host that passes `RemoteURL.isValidHost` always makes an address. If this one does not, nothing is asked.
        guard let url = components.url, url.host == host else { throw ReviewError.otherHost }
        return url
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
    }

    // MARK: Asking

    /// The list of `Element` that `url` answers a GET with.
    ///
    /// Only a 200 is an answer: a redirect is not followed, since a host does not get to send a token on to another
    /// address, and it is no answer. Neither is any other status, nor what is not a JSON list of `Element`.
    static func list<Element: Decodable>(
        of type: Element.Type, at url: URL, headers: [String: String], using session: URLSession
    ) async throws -> [Element] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
        guard let response = response as? HTTPURLResponse else { throw ReviewError.unreadableAnswer }
        guard response.statusCode == 200 else { throw ReviewError.status(response.statusCode) }
        do {
            return try JSONDecoder().decode([Element].self, from: data)
        } catch {
            // What the decoder says is about the shape of what the host sent, and has nothing in it that is of use.
            throw ReviewError.unreadableAnswer
        }
    }

    // MARK: Fields that both services have

    /// `sha` if it is the id of a commit, `nil` if there is none. It is handed to git, and git takes more than an id
    /// for a commit: `HEAD`, a branch or `HEAD~1` would stand for the commit that a worktree has checked out itself.
    /// So it has to be hexadecimal digits and nothing else, and not more of them than a SHA-256 has.
    static func commitID(_ sha: String?) throws -> String? {
        guard let sha else { return nil }
        guard (1...64).contains(sha.utf8.count), sha.utf8.allSatisfy(isHexDigit) else {
            throw ReviewError.unreadableAnswer
        }
        return sha
    }

    /// The address of a page, if `text` is one that a browser opens: `http` or `https`, and a host. Anything else is
    /// left out, since it is opened on a click, and a host does not get to pick what is opened.
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
