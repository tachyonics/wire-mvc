public import HTTPAPIs
public import NIOHTTPServer
public import ServiceLifecycle
import WireMVC

// Test support for a `@WireMVCBootstrap` app. `WireMVCRouteGen` emits a free `withTestServer` entry
// alongside the `@main`: it inlines the SAME build-and-wrap the `@main` does (the finalized+wrapped
// handler is an opaque `~Copyable` type that can't be returned or stored, so the build is inlined and
// the opaque handler handed straight to a generic helper — exactly as the `@main` hands it to
// `WireMVC.serve<Server, Handler>`) and then, instead of serving forever, calls `withTestServer` here:
// it serves on the caller-chosen (ephemeral) port, points a `TestClient` at the bound loopback port,
// runs the test body against it, and cancels. A test drives one real HTTP round-trip end to end.

/// A server that reports the port it bound. `withTestServer` reads it to point the `TestClient` at the
/// ephemeral loopback port the OS assigned (the app binds port `0` under test). This is the one
/// capability the seam needs beyond ``HTTPServer``, which surfaces no bound-address API — `NIOHTTPServer`
/// conforms below via its `listeningAddresses`; a bootstrap returning another server type conforms it to
/// opt that server into `withTestServer`.
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

public enum WireMVCTesting {
    /// Serve `handler` on `server` on its (ephemeral) port, run the graph's collated app-scoped `services`,
    /// point a `TestClient` at the bound loopback port, run `body(client)`, then cancel. The generic
    /// signature mirrors `WireMVC.serve`'s — the `~Copyable` + associated-type constraints let the opaque,
    /// non-returnable finalized+wrapped `handler` flow in by inference — plus a `WireMVCTestServer` bound so
    /// the seam can read the bound port. Serving and the services run as child tasks so `body` drives real
    /// requests concurrently; both are cancelled on the way out.
    public static func withTestServer<Server: HTTPServer & WireMVCTestServer, Handler: HTTPServerRequestHandler, R>(
        on server: Server,
        handler: Handler,
        services: [any Service],
        _ body: (TestClient) async throws -> R
    ) async throws -> R
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
            let result = try await body(TestClient(host: "127.0.0.1", port: port))
            group.cancelAll()
            return result
        }
    }
}
