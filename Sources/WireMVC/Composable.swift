import HTTPTypes
import OpenAPIRuntime
import Wire

/// The surface a facade consumes — the collated controllers as transport contributors. Wire
/// emits this conformance on the generated graph, mapping `handlers` to the handlers
/// `CollectedKey` (see `wireTransportConformance`).
public protocol TransportComposable {
    var handlers: [any TransportContributor] { get }
}

/// Tells Wire to emit `extension _WireGraph: TransportComposable`, mapping `handlers` to the
/// `TransportKeys.handlers` `CollectedKey` product.
public let wireTransportConformance = WireGraphConformanceV1(
    conformsTo: (any TransportComposable).self,
    members: [.init("handlers", from: TransportKeys.handlers)]
)

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

    /// Register a `GET` endpoint serving the graph's wiring model (`introspect()`) as JSON onto a
    /// user-owned transport. Because the target is any `ServerTransport`, this introspection
    /// endpoint is cross-runtime — it mounts on Hummingbird, Vapor, or Lambda unchanged, unlike a
    /// framework-specific one. Mount it where you want (e.g. behind the app's own auth).
    public static func mountIntrospection(
        for graph: some Introspectable,
        on transport: some ServerTransport,
        at path: String = "/wiring"
    ) throws {
        let model = graph.introspect()
        try transport.register(
            { _, _, _ in try WireMVCResponse.json(model, status: .ok) },
            method: .get,
            path: path
        )
    }
}
