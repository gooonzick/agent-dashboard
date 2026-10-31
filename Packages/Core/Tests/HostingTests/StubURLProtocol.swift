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

    private struct State: Sendable {
        var routes: [String: StubReply]
        var requests: [URLRequest] = []
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

    /// Every request that has reached this server, in the order it came.
    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// The paths of `requests`.
    var paths: [String] { requests.map { $0.url?.path ?? "" } }

    fileprivate static func server(at host: String?) -> StubServer? {
        host.flatMap { host in servers.withLock { $0[host.lowercased()] } }
    }

    fileprivate func reply(to request: URLRequest) -> StubReply {
        state.withLock { state in
            state.requests.append(request)
            return state.routes[request.url?.path ?? ""] ?? .status(404)
        }
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
        switch server.reply(to: request) {
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
        case .never:
            break
        }
    }

    override func stopLoading() {}

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
