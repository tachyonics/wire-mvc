public import HTTPTypes
public import Wire

// The WireMVC annotation surface. `@Controller` is the one macro that does work — it walks the
// controller's routes and generates the `RouteContributor` witness. The verb, param, and response
// annotations are markers `@Controller` reads (verbs/responses are no-op peer macros; the param
// bindings are `@propertyWrapper`s in RequestBinding.swift).

/// Tells Wire that `@Controller` aliases `@Contributes(to: RouteKeys.handlers)`, so a controller
/// needs only `@Singleton @Controller` — the plugin collates it without a separate `@Contributes`.
public let wireMVCControllerAlias = WireAdapterAnnotationV1(
    annotation: "Controller",
    contributesTo: RouteKeys.handlers
)

/// Generates a `RouteContributor` conformance registering each `@Get`/`@Post`/… route onto a
/// `some RoutableHTTPServerBuilder`, under the optional path prefix. `@Singleton @Controller("/users")`
/// is all an app-scoped controller needs.
@attached(extension, conformances: RouteContributor, names: named(registerWireHandlers(on:)))
public macro Controller(_ path: String) =
    #externalMacro(module: "WireMVCMacros", type: "ControllerMacro")

/// Generates the `RouteContributor` conformance with no path prefix (routes carry the full path on
/// their verb annotation).
@attached(extension, conformances: RouteContributor, names: named(registerWireHandlers(on:)))
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
