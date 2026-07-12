public import HTTPAPIs
public import Wire

/// The surface a facade consumes — the collated controllers as route contributors. Wire emits this
/// conformance on the generated graph, mapping `handlers` to the handlers `CollectedKey` (see
/// `wireRouteConformance`).
public protocol RouteComposable {
    var handlers: [any RouteContributor] { get }
}

/// Tells Wire to emit `extension _WireGraph: RouteComposable`, mapping `handlers` to the
/// `RouteKeys.handlers` `CollectedKey` product.
public let wireRouteConformance = WireGraphConformanceV1(
    conformsTo: (any RouteComposable).self,
    members: [.init("handlers", from: RouteKeys.handlers)]
)

public enum WireMVC {
    /// Build the request handler for `server` from the graph's collated controllers. Pass the
    /// result to `server.serve(handler:)`:
    ///
    /// ```swift
    /// let graph = try await Wire.bootstrap()
    /// let router = try WireMVC.router(for: graph, server: server)
    /// try await server.serve(handler: router)
    /// ```
    ///
    /// The router is generic over the server's associated `Reader`/`ResponseSender`; the inverse
    /// (`~Copyable`) requirements are restated here because they don't propagate across the generic
    /// boundary on their own.
    public static func router<Graph: RouteComposable, Server: HTTPServer>(
        for graph: Graph,
        server: borrowing Server
    ) throws -> WireRouter<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        var router = WireRouter<Server.RequestContext, Server.Reader, Server.ResponseSender>()
        for contributor in graph.handlers {
            try contributor.registerWireHandlers(on: &router)
        }
        return router
    }

    /// Register a `GET` endpoint serving the graph's wiring model (`introspect()`) as JSON onto a
    /// router (or any `RoutableHTTPServerBuilder`). The model is encoded once, at mount time.
    public static func mountIntrospection<Builder: RoutableHTTPServerBuilder>(
        for graph: some Introspectable,
        into builder: inout Builder,
        at path: String = "/wiring"
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        let outcome = try WireMVCResponse.json(graph.introspect(), status: .ok)
        builder.register(method: .get, path: path) { _, _, _, responseSender in
            try await outcome.send(on: responseSender)
        }
    }
}
