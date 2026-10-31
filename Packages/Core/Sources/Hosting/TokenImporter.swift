import Foundation
import Shell

/// Takes over the token that `glab` or `gh` already has for a host, so that the user does not make a second one.
public struct TokenImporter: Sendable {
    /// How long a tool may take. It reads its own configuration or the Keychain, which is all but instant.
    private static let timeout: Duration = .seconds(15)

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// The token that `glab config get token --host <host>` (for GitLab) or `gh auth token --hostname <host>` (for
    /// GitHub) prints, without the newline that ends it.
    ///
    /// `nil` is every way in which there is none: a kind that has no tool, a name that is no host, a tool that is not
    /// installed, a run that fails or runs out of time, an exit that is not 0, and output that is empty or is not a
    /// token. A token is one word of printable ASCII, so a message that a tool printed in its place is none, nor is
    /// anything that must not go into a header. Nothing is logged: the output is the secret.
    public func importToken(host: String, kind: HostingKind) async -> String? {
        // The host is an argument of another program. A name that is no host name cannot pose as one of its options.
        guard RemoteURL.isValidHost(host) else { return nil }
        let tool: String
        let arguments: [String]
        switch kind {
        case .gitlab: (tool, arguments) = ("glab", ["config", "get", "token", "--host", host])
        case .github: (tool, arguments) = ("gh", ["auth", "token", "--hostname", host])
        case .unsupported: return nil
        }
        // A tool that is not installed has no executable, and running it throws `CommandError.notFound`: it is the
        // same case as any other run that does not work.
        guard let result = try? await runner.run(tool, arguments, in: nil, timeout: Self.timeout),
            result.exitCode == 0
        else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return token
    }
}
