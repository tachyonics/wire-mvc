public import Wire

/// The surface a facade consumes — the collated controllers as route contributors. Wire emits this
/// conformance on the generated graph, mapping `routeContributors` to the `CollectedKey` (see
/// `wireRouteConformance`).
public protocol RouteComposable {
    var routeContributors: [any RouteContributor] { get }
}

/// Tells Wire to emit `extension _WireGraph: RouteComposable`, mapping `routeContributors` to the
/// `WireMVCKeys.routeContributors` `CollectedKey` product.
public let wireRouteConformance = WireGraphConformanceV1(
    conformsTo: (any RouteComposable).self,
    members: [.init("routeContributors", from: WireMVCKeys.routeContributors)]
)

public enum WireMVC {
    /// Register the graph's collated controllers onto a route builder — any
    /// `RoutableHTTPServerBuilder` (a router, an adapter's builder). WireMVC stays router-agnostic,
    /// exactly as the old `apply` stayed transport-agnostic over `some ServerTransport`; the concrete
    /// builder — which is also the proposal's `HTTPServerRequestHandler`, so it can serve — is the
    /// caller's:
    ///
    /// ```swift
    /// let graph = try await Wire.bootstrap()
    /// var router = WireRouter(for: server)   // a concrete RoutableHTTPServerBuilder + handler
    /// try WireMVC.apply(graph, to: &router)
    /// try await server.serve(handler: router)
    /// ```
    ///
    /// The inverse (`~Copyable`) requirements are restated here because they don't propagate across
    /// the generic boundary on their own.
    public static func apply<Builder: RoutableHTTPServerBuilder>(
        _ graph: some RouteComposable,
        to builder: inout Builder
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        for contributor in graph.routeContributors {
            try contributor.registerWireRoutes(on: &builder)
        }
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
