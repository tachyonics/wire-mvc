public import HTTPAPIs
public import NIOHTTPServer
public import ServiceLifecycle
public import Testing
import WireMVC

// Test support for a `@WireMVCBootstrap` app. The one public way to stand up a test server is the suite
// trait `@Suite(.wiremvc())`: `WireMVCRouteGen` emits, in a test consumer, a `.wiremvc()` factory whose
// closure inlines the SAME build-and-wrap the `@main` does (the finalized+wrapped handler is an opaque
// `~Copyable` type that can't be returned or stored, so the build is inlined and the opaque handler handed
// straight to `serveForSuite` — exactly as the `@main` hands it to `WireMVC.serve<Server, Handler>`). The
// trait runs that closure once at suite entry: it serves on the caller-chosen (ephemeral) port, points
// `TestClient.current` at the bound loopback port for the suite's tests, runs them, and cancels at suite
// exit. Each test call drives one real HTTP round-trip end to end.

/// A server that reports the port it bound. `serveForSuite` reads it to point `TestClient.current` at the
/// ephemeral loopback port the OS assigned (the app binds port `0` under test). This is the one capability
/// the seam needs beyond ``HTTPServer``, which surfaces no bound-address API — `NIOHTTPServer` conforms
/// below via its `listeningAddresses`; a bootstrap returning another server type conforms it to opt that
/// server into the suite trait.
public protocol WireMVCTestServer {
    /// The port the server is listening on, once bound. Suspends until the first address binds.
    var wireMVCBoundPort: Int { get async throws }
}

extension NIOHTTPServer: WireMVCTestServer {
    public var wireMVCBoundPort: Int {
        get async throws {
            guard let port = try await listeningAddresses.first?.port else {
                throw WireMVCTestingError.noListeningPort
            }
            return port
        }
    }
}

/// A failure reaching the running test server — the server bound no listening address to read a port from.
public enum WireMVCTestingError: Error {
    case noListeningPort
}

/// The suite trait standing up a `@WireMVCBootstrap` app's test server — `@Suite(.wiremvc())`. Non-generic
/// (the server and opaque `~Copyable` handler types stay inside `serve`, which the generated `.wiremvc()`
/// factory closes over): it holds a type-erasing serve closure that builds + serves the app and runs the
/// suite's tests inside it. `provideScope` runs `serve` once at suite entry (not per test case), threading
/// the tests through as `runTests`. `serve` cancels the server on the way out (suite exit).
public struct WireMVCSuiteTrait: SuiteTrait, TestScoping {
    public let isRecursive = false

    /// Builds + serves the app, then runs `runTests` against it and cancels — supplied by the generated
    /// `.wiremvc()` factory, which inlines the build and calls ``WireMVCTesting/serveForSuite(on:handler:services:runTests:)``.
    let serve: @Sendable (_ runTests: @concurrent @Sendable () async throws -> Void) async throws -> Void

    public init(
        serve: @escaping @Sendable (_ runTests: @concurrent @Sendable () async throws -> Void) async throws -> Void
    ) {
        self.serve = serve
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing execute: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // Only scope at suite level, not individual test cases — the server stands up once for the whole
        // suite, and each test case runs against the shared client.
        guard testCase == nil else {
            try await execute()
            return
        }
        try await serve { try await execute() }
    }
}

public enum WireMVCTesting {
    /// Serve `handler` on `server` on its (ephemeral) port, run the graph's collated app-scoped `services`,
    /// point `TestClient.current` at the bound loopback port, run `runTests()`, then cancel. The internal
    /// mechanism the ``WireMVCSuiteTrait``'s generated `.wiremvc()` factory hands its inlined build to. The
    /// generic signature mirrors `WireMVC.serve`'s — the `~Copyable` + associated-type constraints let the
    /// opaque, non-returnable finalized+wrapped `handler` flow in by inference — plus a `WireMVCTestServer`
    /// bound so the seam can read the bound port. Serving and the services run as child tasks so the tests
    /// drive real requests concurrently; both are cancelled on the way out.
    public static func serveForSuite<Server: HTTPServer & WireMVCTestServer, Handler: HTTPServerRequestHandler>(
        on server: Server,
        handler: Handler,
        services: [any Service],
        runTests: @concurrent @Sendable () async throws -> Void
    ) async throws
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable,
        Handler.RequestContext == Server.RequestContext,
        Handler.Reader == Server.Reader,
        Handler.ResponseSender == Server.ResponseSender
    {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await WireMVC.runServices(services) }
            group.addTask { try await server.serve(handler: handler) }
            let port = try await server.wireMVCBoundPort
            try await TestClient.$currentStorage.withValue(TestClient(host: "127.0.0.1", port: port)) {
                try await runTests()
            }
            group.cancelAll()
        }
    }
}
