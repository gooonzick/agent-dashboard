import Foundation
import Synchronization

/// What a `StubServer` answers to a request.
enum StubReply: Sendable {
    /// An answer with this HTTP status. The body is what a real server sends along with it: code that wants only the
    /// status has to cope with a body that it never reads.
    case status(Int, body: Data = Data())
    /// No answer: the connection fails, as it does when the name does not resolve or the certificate is wrong.
    case failure(URLError.Code)
    /// A 302 that points at `target`. As with a real server, the caller decides whether to follow it.
    case redirect(to: URL)
    /// No answer, ever: the request stays open until it is cancelled or runs out of time.
    case never
    /// No answer yet: the request is held until the test calls `StubServer.unblock(_:with:)`. Unlike `never`, it ends
    /// when the test says so, and so a test can have a request in flight for as long as it needs.
    case held
}

/// A web server that lives inside the test process, for code that talks HTTP through a `URLSession` it is given.
///
/// Every server has a host of its own and answers by path. Tests run side by side, and what keeps them apart is that
/// no two of them share a host: a test makes its own server, and a request is looked up by the host it is for. (A test
/// that needs a particular name makes its server with `host:`, and then no other test may use that name.)
///
/// `session` is an ephemeral session whose own configuration names `StubURLProtocol`. Nothing is registered for the
/// whole process, and a request for a host that has no server fails without leaving it.
final class StubServer: Sendable {
    let host: String
    let session: URLSession

    /// A request that is held back, and the way to answer it. A `URLProtocol` is not `Sendable`, but its client may be
    /// called from any thread, and this is used for nothing else than answering the one request that it stands for.
    private struct HeldLoad: @unchecked Sendable {
        let path: String
        let load: StubURLProtocol
    }

    private struct State: Sendable {
        var routes: [String: StubReply]
        var requests: [URLRequest] = []
        var held: [HeldLoad] = []
    }
    private let state: Mutex<State>

    private static let servers = Mutex<[String: StubServer]>([:])

    /// A server that answers the paths in `routes` as given, and every other path with a 404.
    init(host: String = "\(UUID().uuidString.lowercased()).stub.test", routes: [String: StubReply] = [:]) {
        self.host = host
        state = Mutex(State(routes: routes))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        Self.servers.withLock { $0[host] = self }
    }

    /// From now on, `path` is answered with `reply`.
    func answer(_ path: String, with reply: StubReply) {
        state.withLock { $0.routes[path] = reply }
    }

    /// From now on, `path` is answered with `reply`, and so is every request for it that is being held (`.held`).
    func unblock(_ path: String, with reply: StubReply) {
        let released = state.withLock { state in
            state.routes[path] = reply
            let released = state.held.filter { $0.path == path }
            state.held.removeAll { $0.path == path }
            return released
        }
        for held in released { held.load.deliver(reply) }
    }

    /// Answers the request for `path` that has been held the longest with `reply`, and leaves the rest held, and the
    /// answer to later requests as it is.
    func unblockOldest(_ path: String, with reply: StubReply) {
        let oldest = state.withLock { state -> HeldLoad? in
            guard let index = state.held.firstIndex(where: { $0.path == path }) else { return nil }
            return state.held.remove(at: index)
        }
        oldest?.load.deliver(reply)
    }

    /// How many requests are being held at this moment.
    var heldCount: Int { state.withLock { $0.held.count } }

    /// Every request that has reached this server, in the order it came.
    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// The paths of `requests`.
    var paths: [String] { requests.map { $0.url?.path ?? "" } }

    fileprivate static func server(at host: String?) -> StubServer? {
        host.flatMap { host in servers.withLock { $0[host.lowercased()] } }
    }

    /// What to answer `request` with, or `nil` if it is to be held: `load` then waits for `unblock`.
    fileprivate func reply(to request: URLRequest, from load: StubURLProtocol) -> StubReply? {
        state.withLock { state in
            state.requests.append(request)
            let path = request.url?.path ?? ""
            let reply = state.routes[path] ?? .status(404)
            guard case .held = reply else { return reply }
            state.held.append(HeldLoad(path: path, load: load))
            return nil
        }
    }

    /// The request of `load` is over, as it is when its task is cancelled: nothing is left to answer.
    fileprivate func forget(_ load: StubURLProtocol) {
        state.withLock { state in state.held.removeAll { $0.load === load } }
    }
}

/// Plays the part of the network for the sessions of `StubServer`.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = StubServer.server(at: url.host) else {
            return fail(.cannotFindHost)
        }
        // A request that is held is answered later, by `deliver`, when the test lets it go.
        if let reply = server.reply(to: request, from: self) { deliver(reply) }
    }

    /// Answers the request with `reply`.
    fileprivate func deliver(_ reply: StubReply) {
        guard let url = request.url else { return fail(.badURL) }
        switch reply {
        case .status(let status, let body):
            respond(to: url, status: status, headers: [:], body: body)
        case .failure(let code):
            fail(code)
        case .redirect(let target):
            guard
                let redirect = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString])
            else { return fail(.badServerResponse) }
            // The loading system asks the task's delegate whether to go to the target, and starts a new load if it
            // says yes. If it says no, the 302 is what the caller gets, so it has to be sent as well: a real server
            // has sent it already.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            respond(to: url, status: 302, headers: ["Location": target.absoluteString], body: Data())
        case .never, .held:
            break
        }
    }

    override func stopLoading() {
        StubServer.server(at: request.url?.host)?.forget(self)
    }

    private func respond(to url: URL, status: Int, headers: [String: String], body: Data) {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return fail(.badServerResponse) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}
