public import HTTPTypes
public import Wire

// The WireMVC annotation surface. `@Controller` is the one macro that does work — it walks the
// controller's routes and generates the `RouteContributor` witness. The verb, param, and response
// annotations are markers `@Controller` reads (verbs/responses are no-op peer macros; the param
// bindings are `@propertyWrapper`s in RequestBinding.swift).

/// Tells Wire that `@Controller` contributes a generated **proxy** — `_WireRouteContributor_<Controller>`
/// — into `WireMVCKeys.routeContributors`, not the controller itself. swift-wire's contributor-proxy
/// synthesis constructs the proxy (depending on the controller plus any factories its `@Middleware(key)`
/// use-sites demand) and collates that. So a controller needs only `@Singleton @Controller` and stays a
/// plain, footgun-free binding — the proxy is the only type that holds the lifted factories.
public let wireMVCControllerAlias = WireAdapterAnnotationV1(
    annotation: "Controller",
    capability: .contributesProxy(to: WireMVCKeys.routeContributors, proxyTypePrefix: "_WireRouteContributor_")
)

/// `@Middleware(key)` declares that the annotated controller requires the factory synthesised from the
/// keyed `@Factory` middleware template — the `.injectsFactoryOnArgument` capability. The plugin lifts
/// the factory onto the controller's generated route-contributor proxy (the type that folds the
/// middleware). (The `.self` forms of `@Middleware` are read inline by `@Controller` and constructed
/// there, not factory cases; the synthesis skips them.)
public let wireMVCMiddlewareFactoryAlias = WireAdapterAnnotationV1(
    annotation: "Middleware",
    capability: .injectsFactoryOnArgument
)

/// Generates a `RouteContributor` proxy registering each `@Get`/`@Post`/… route onto a
/// `some RoutableHTTPServerBuilder`, under the optional path prefix. `@Singleton @Controller("/users")`
/// is all an app-scoped controller needs.
@attached(peer, names: prefixed(_WireRouteContributor_))
public macro Controller(_ path: String) =
    #externalMacro(module: "WireMVCMacros", type: "ControllerMacro")

/// Generates the proxy with no path prefix (routes carry the full path on their verb annotation).
@attached(peer, names: prefixed(_WireRouteContributor_))
public macro Controller() =
    #externalMacro(module: "WireMVCMacros", type: "ControllerMacro")

// ── HTTP verb markers (peer, no-op — read by `@Controller`) ──

@attached(peer)
public macro Get(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Get() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Post(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Post() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Put(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Put() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Patch(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Patch() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Delete(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Delete() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ── Response markers (peer, no-op — read by `@Controller`) ──

/// The route returns an `Encodable` body, encoded as JSON with the given status (default 200).
@attached(peer)
public macro JSONResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro JSONResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The route returns no body; the response carries the given status.
@attached(peer)
public macro ResponseStatus(_ status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The raw escape hatch: the handler receives the request, matched path parameters, the body reader,
/// and the response sender verbatim (no param decode, no response encode) and writes the response
/// itself. Use for streaming/SSE/proxying. The handler is generic over the reader/sender (the builder's
/// associated types); take only the primitives you need — `HTTPRequest`, `[String: Substring]`, the
/// `AsyncReader`-constrained reader, the `HTTPResponseSender`-constrained sender — in any order.
/// Stands in for the response annotation (a `@RawRoute` needs no `@JSONResponse`/`@ResponseStatus`).
@attached(peer)
public macro RawRoute() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// Wrap a route (or, on the controller type, every route) in a `Middleware`. `T` is a graph binding
/// that is the proposal's `Middleware` over the request/response box — it runs before the handler and
/// can transform the box (e.g. enrich the `RequestContext`). Controller-scope `@Middleware` wraps
/// outer, route-scope inner: `controller-outer → route-inner → handler`. The `@Controller` macro reads
/// these off the type and each function; they expand to nothing themselves.
@attached(peer)
public macro Middleware<T>(_ type: T.Type) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The factory case — `@Middleware(key)` where `key` is a `FactoryKey` naming a generic-with-deps
/// middleware's `@Factory` template. The plugin synthesises the factory (`_WireFactory_<key>`), lifts
/// it onto the controller, and the `@Controller` macro calls its `create` in the fold. See
/// `wireMVCMiddlewareFactoryAlias`.
@attached(peer)
public macro Middleware(_ key: FactoryKey) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
