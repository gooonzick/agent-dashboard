import Foundation
import Hosting
import Testing

@Suite struct RemoteURLTests {
    // MARK: What the brief asks for

    @Test(arguments: [
        ("git@gitlab.diftech.org:pyme-web/dashboard.git", "gitlab.diftech.org", nil, "pyme-web/dashboard"),
        ("ssh://git@git.example.com:2222/a/b/c.git", "git.example.com", 2222, "a/b/c"),
        ("https://github.com/gooonzick/meetily.git", "github.com", nil, "gooonzick/meetily"),
        ("https://user:pw@gitlab.example.org/team/app", "gitlab.example.org", nil, "team/app"),
    ])
    func parsesRemotes(raw: String, host: String, port: Int?, path: String) throws {
        let r = try #require(RemoteURL(raw))
        #expect(r.host == host && r.port == port && r.projectPath == path)
    }

    @Test func rejectsGarbage() { #expect(RemoteURL("not a url") == nil) }

    // What the brief's examples leave open: the other ways git writes a remote, and the care that a value needs that
    // is compared, looked up by host and put in a request.

    // MARK: Forms

    @Test(arguments: [
        // `scp`-like, which has no scheme and cannot carry a port; the user is optional.
        ("gitlab.example.org:team/app.git", "gitlab.example.org", nil, "team/app"),
        ("git@10.0.0.5:team/app.git", "10.0.0.5", nil, "team/app"),
        ("git@gitserver:team/app.git", "gitserver", nil, "team/app"),
        // The schemes git speaks to a hosting service with.
        ("git://github.com/a/b.git", "github.com", nil, "a/b"),
        ("ssh://git@host.example/a/b", "host.example", nil, "a/b"),
        ("git+ssh://git@host.example/a/b.git", "host.example", nil, "a/b"),
        ("ssh+git://git@host.example/a/b.git", "host.example", nil, "a/b"),
        ("http://localhost:3000/a/b.git", "localhost", 3000, "a/b"),
        ("https://gitlab.example.org:8443/team/app.git", "gitlab.example.org", 8443, "team/app"),
        ("ssh://git@host.example:/a/b.git", "host.example", nil, "a/b"),  // an empty port is no port
    ])
    func readsTheFormsOfARemote(raw: String, host: String, port: Int?, path: String) throws {
        let r = try #require(RemoteURL(raw))
        #expect(r.host == host && r.port == port && r.projectPath == path)
    }

    @Test(arguments: [
        ("https://github.com/gooonzick/meetily", "gooonzick/meetily"),
        ("https://github.com/gooonzick/meetily.git/", "gooonzick/meetily"),
        ("https://github.com//gooonzick//meetily.git", "gooonzick/meetily"),
        ("ssh://git@gitlab.example.org/group/sub/deeper/repo.git", "group/sub/deeper/repo"),
        ("https://gitlab.example.org/team/my.app.git", "team/my.app"),  // only a final `.git` goes
        ("https://github.com/gooonzick/.github.git", "gooonzick/.github"),
        ("  git@github.com:a/b.git\n", "a/b"),
    ])
    func shapesTheProjectPath(raw: String, path: String) throws {
        let r = try #require(RemoteURL(raw))
        #expect(r.projectPath == path)
    }

    @Test(arguments: [
        ("https://GitLab.Example.ORG/Team/App.git", "gitlab.example.org", "Team/App"),
        ("git@GitHub.com:Owner/Repo.git", "github.com", "Owner/Repo"),
        ("HTTPS://GITHUB.COM/Owner/Repo", "github.com", "Owner/Repo"),
    ])
    func comparesHostsWithoutRegardToCase(raw: String, host: String, path: String) throws {
        // A host is not case sensitive, a project path may be: only the host is lowercased.
        let r = try #require(RemoteURL(raw))
        #expect(r.host == host && r.projectPath == path)
        #expect(r == RemoteURL("https://\(host)/\(path)"))
    }

    // MARK: Not a remote of a hosting service

    @Test(arguments: [
        "", "   ", "not a url", "repo.git", "/Users/me/repo.git", "../repo.git", "~/repo.git",
        "file:///Users/me/repo.git",  // no host
        "ftp://host.example/a/b.git",  // not a way to reach a hosting service
        "https://", "https://github.com", "https://github.com/", "https://:8080/a/b",
        "https://github.com/onlyone", "git@github.com:onlyone.git", "git@github.com:", "git@:a/b.git",
        "https://host.example/a/.git",  // nothing is left of the name
        "https://exa mple.com/a/b", "git@github.com:a/b c.git",
        "https://host.example:abc/a/b", "https://host.example:99999/a/b", "https://host.example:0/a/b",
        "https://host.example:-1/a/b", "ssh://git@host.example:22:33/a/b",
        "https://[::1]/a/b",  // an IPv6 address is not a name that a request can be made to by `host`
        "https://ünï.example/a/b",  // host names are ASCII
        "https://host.example/a/../b", "https://host.example/a/./b", "https://host.example/..",
    ])
    func rejectsWhatIsNoRemoteOfAHostingService(raw: String) {
        #expect(RemoteURL(raw) == nil)
    }

    // MARK: Credentials

    @Test(arguments: [
        "https://user:S3CRET@gitlab.example.org/team/app.git",
        "https://oauth2:glpat-S3CRET@gitlab.example.org/team/app.git",
        "https://x-access-token:S3CRET@github.com/team/app.git",
        "https://S3CRET@gitlab.example.org/team/app",
        "https://us:er:S3CRET@gitlab.example.org/team/app",
        "https://user:p@S3CRET@gitlab.example.org/team/app",  // an `@` in the password that nobody escaped
        "ssh://S3CRET@gitlab.example.org:2222/team/app.git",
        "S3CRET@gitlab.example.org:team/app.git",
    ])
    func neverKeepsCredentials(raw: String) throws {
        let remote = try #require(RemoteURL(raw))
        var dumped = ""
        dump(remote, to: &dumped)
        let shown = [
            remote.host, remote.projectPath, String(describing: remote), String(reflecting: remote), dumped,
            String(decoding: try JSONEncoder().encode(remote), as: UTF8.self),
        ]

        #expect(remote.host == "gitlab.example.org" || remote.host == "github.com")
        for text in shown {
            #expect(!text.contains("S3CRET"), "\(text)")
            #expect(!text.contains("oauth2") && !text.contains("x-access-token"), "\(text)")
        }
    }

    @Test(arguments: [
        // A URL that was typed or pasted wrongly can put the rest of a credential where a host or a path goes. Such a
        // URL is no remote, and nothing of the secret may survive in a field that is stored, shown or logged.
        "https://tok/S3CRET@host.example/a/b",
        "https://user:pa/S3CRET@host.example/a/b",
        "https://host.example:S3CRET/a/b",
        "https://host.example/a/b?token=S3CRET",
        "https://host.example/a/b#S3CRET",
    ])
    func aMalformedUrlDoesNotSmuggleACredentialIntoAField(raw: String) {
        #expect(RemoteURL(raw) == nil)
    }

    // MARK: Value semantics

    @Test func survivesEncodingAndDecoding() throws {
        let remote = try #require(RemoteURL("ssh://git@Git.Example.com:2222/a/b/c.git"))
        let data = try JSONEncoder().encode(remote)
        #expect(try JSONDecoder().decode(RemoteURL.self, from: data) == remote)
    }

    @Test func remotesThatDifferOnlyInTheCaseOfTheHostAreOne() throws {
        let one = try #require(RemoteURL("https://GITHUB.com/a/b"))
        let other = try #require(RemoteURL("https://github.com/a/b"))
        #expect(one == other)
        #expect(Set([one, other]).count == 1)
        #expect(one != RemoteURL("https://github.com/a/c"))
        #expect(one != RemoteURL("ssh://git@github.com:2222/a/b"))  // the port is part of the address
    }
}
