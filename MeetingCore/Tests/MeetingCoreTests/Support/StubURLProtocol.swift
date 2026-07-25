import Foundation

struct StubResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    /// Delivered as separate `didLoad` calls, so tests exercise chunk splitting.
    var chunks: [String] = []
}

/// Each test registers its response against a unique URL, so concurrently
/// running tests never share fixture state.
///
/// This shape is deliberate: an earlier version used shared static fixtures and
/// tests clobbered each other under Swift Testing's parallel execution. Do not
/// "simplify" it back to globals.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var table: [URL: StubResponse] = [:]

    static func register(_ response: StubResponse) -> URL {
        let url = URL(string: "https://stub.test/\(UUID().uuidString)")!
        lock.lock()
        table[url] = response
        lock.unlock()
        return url
    }

    private static func stub(for url: URL) -> StubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return table[url]
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
