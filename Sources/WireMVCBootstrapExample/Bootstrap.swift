import HTTPAPIs
import Logging
import NIOHTTPServer
import Wire
import WireMVC
import WireMVCRouter

// The WireMVC-native composition root. `@Singleton` makes it a graph binding (its `@Inject` resolves);
// `@WireMVCBootstrap` makes the plugin generate the program entry point (`@main`). There is no
// `main.swift` and no hand-written `@main` — `swift run WireMVCBootstrapExample` bootstraps the graph,
// constructs this type, registers the collated `HelloController` onto the package `WireRouter`, and
// serves on 127.0.0.1:8080.

@Singleton
@WireMVCBootstrap
@ErrorResponse(TenantMissing.self, .badRequest)  // global default tier — folds into every route (Phase 3)
struct AppBootstrap {
    @Inject let config: ServerConfig

    // Returns the *concrete* server, not `some HTTPServer`: the proposal's `Reader`/`ResponseSender`
    // are `~Copyable`, which a bare `some HTTPServer` opaque return can't express. The generated
    // `@main` binds to whatever concrete type this returns.
    func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "WireMVCBootstrapExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: config.host, port: config.port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    // The package-provided `TrieRouteBuilder` is a `FinalizableHTTPServerRouteBuilder`: `WireMVC.apply`
    // registers routes onto it, and the generated `@main` `finalize()`s it into the immutable
    // `FrozenTrieRouter` the server serves (build → freeze → serve).
    func createRouteBuilder<Server: HTTPServer>(
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)
    }
}
