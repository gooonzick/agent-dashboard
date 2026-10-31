import Foundation
import Security

/// Keeps the access token of each host.
public protocol TokenStoring: Sendable {
    /// The token stored for `host`, or `nil` if there is none. Throws if the store cannot be read: a store that cannot
    /// be read is not an empty one.
    func token(for host: String) throws -> String?

    /// Stores `token` for `host`, in place of the one that is there. `nil` removes the token, and so does a token that
    /// is empty: an empty one is no token, and a client would send it as one. Removing a token that is not there is no
    /// error.
    func setToken(_ token: String?, for host: String) throws
}

/// Why a token could not be read from, or written to, the Keychain.
public enum TokenStoreError: Error, Equatable, LocalizedError {
    /// The Keychain refused, with this status.
    case keychain(OSStatus)
    /// An entry is there, but what it holds is not text. A token is never that, and reading it as one would make up
    /// a token that is not the one stored.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain failed: \(message)"
        case .unreadable:
            return "The Keychain entry of this host does not hold a token."
        }
    }
}

/// Keeps the tokens in the login keychain of the user, as generic passwords: the host is the account, the token is the
/// secret. A host is not case sensitive, so the account is the host in lowercase.
public struct KeychainTokenStore: TokenStoring {
    /// What the entries are filed under in the Keychain. The default is the service of the app; a test that uses a
    /// store takes a service of its own, so that it neither reads nor changes what the user has stored.
    public let service: String

    public init(service: String = "dev.gooonzick.AgentDashboard.hosting") {
        self.service = service
    }

    public func token(for host: String) throws -> String? {
        var query = entry(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            guard let data = found as? Data, let token = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.unreadable
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychain(status)
        }
    }

    public func setToken(_ token: String?, for host: String) throws {
        let entry = entry(for: host)
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(entry as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenStoreError.keychain(status)
            }
            return
        }
        let secret = Data(token.utf8)
        var status = SecItemUpdate(entry as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(entry.merging([kSecValueData as String: secret]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
    }

    /// The attributes that make up the entry of `host`, which is all that finds it.
    private func entry(for host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.lowercased(),
        ]
    }
}
