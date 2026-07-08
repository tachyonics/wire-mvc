import OpenAPIRuntime

/// The surface a facade consumes — the collated controllers as transport contributors.
/// (In the graph-integrated build, Wire emits this conformance on the generated graph from
/// the handlers `CollectedKey`; here it's the shape `apply` registers.)
public protocol TransportComposable {
    var handlers: [any TransportContributor] { get }
}

public enum WireMVC {
    /// Register the collated controllers' routes onto a user-owned transport (a Hummingbird
    /// `Router`, a Vapor `Application`, a Lambda transport — any `ServerTransport`).
    public static func apply(
        _ graph: some TransportComposable,
        to transport: some ServerTransport
    ) throws {
        for contributor in graph.handlers {
            try contributor.registerWireHandlers(on: transport)
        }
    }
}
