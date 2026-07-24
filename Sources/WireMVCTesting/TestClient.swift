public import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A minimal typed HTTP client over `URLSession`, pointed at the loopback port `serveForSuite` bound.
// The surface is the small verb set a controller test drives — `get`/`post`/`patch`/`delete` — each
// returning a `TestResponse` that exposes the status, the raw body text, and typed JSON decoding. A test
// reaches the running suite server's client through the static `TestClient.current`.

/// A typed HTTP client bound to a running test server's loopback host + port. Each call drives one real
/// HTTP round-trip and returns a ``TestResponse``.
public struct TestClient: Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The client for the running `@Suite(.wiremvc())` suite server, bound to its loopback port for the
    /// duration of the suite by ``WireMVCTesting/serveForSuite(on:handler:services:runTests:)``. Read it
    /// inside a suite-trait suite (e.g. `TestClient.current.post(...)`); `nil` outside such a suite.
    @TaskLocal static var _current: TestClient?

    /// The client for the running `@Suite(.wiremvc())` suite server. Available only inside a suite the
    /// trait scopes — outside one there is no server to reach, so this precondition-fails.
    public static var current: TestClient {
        guard let client = _current else {
            preconditionFailure("TestClient.current is only available inside an @Suite(.wiremvc()) suite")
        }
        return client
    }

    /// `GET path`.
    public func get(_ path: String, headers: [String: String] = [:]) async throws -> TestResponse {
        try await send("GET", path, body: nil, headers: headers)
    }

    /// `POST path` with `json` encoded as the JSON body (`Content-Type: application/json`).
    public func post(
        _ path: String,
        json: some Encodable,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send("POST", path, body: try JSONEncoder().encode(json), headers: jsonHeaders(headers))
    }

    /// `PATCH path` with `json` encoded as the JSON body (`Content-Type: application/json`).
    public func patch(
        _ path: String,
        json: some Encodable,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send("PATCH", path, body: try JSONEncoder().encode(json), headers: jsonHeaders(headers))
    }

    /// `DELETE path`.
    public func delete(_ path: String, headers: [String: String] = [:]) async throws -> TestResponse {
        try await send("DELETE", path, body: nil, headers: headers)
    }

    private func jsonHeaders(_ headers: [String: String]) -> [String: String] {
        var merged = headers
        merged["Content-Type"] = "application/json"
        return merged
    }

    private func send(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> TestResponse {
        let request = makeRequest(method, path, body: body, headers: headers)
        let (data, response) = try await URLSession.shared.data(for: request)
        return TestResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    /// Build the `URLRequest` for one call, stamping the correlation header when inside a `withBindValues`
    /// closure. Split from ``send(_:_:body:headers:)`` so the header-stamping is unit-testable without a
    /// round-trip.
    func makeRequest(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Inside a `withBindValues` closure the task-local carries the request's correlation id; stamp it so
        // the dispatch can pull that closure's doubles from the store. Outside a closure it's nil — no header.
        if let id = WireMVCTesting.currentCorrelationID {
            request.setValue(id.rawValue.uuidString, forHTTPHeaderField: wireMVCTestBindsHeader)
        }
        return request
    }
}

/// The result of a `TestClient` request — status code and body, with typed JSON decoding.
public struct TestResponse: Sendable {
    /// The HTTP status code.
    public let status: Int
    /// The raw response body bytes.
    public let body: Data

    /// The response body decoded as UTF-8 text.
    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }

    /// Decode the response body as JSON into `type`.
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}
