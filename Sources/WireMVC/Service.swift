public import ServiceLifecycle
public import Wire

// The service collation feature: the collation key, the `@BackgroundService` macro, and the
// contribution alias. `Service` is referenced in the key's `CollectedKey<any Service>` and in the
// macro's `conformances:`, so `import ServiceLifecycle` is genuinely used here.

extension WireMVCKeys {
    /// App-scoped `ServiceLifecycle` services (a database client, a connection pool) the graph runs
    /// alongside the server, handed to the app's `ServiceGroup` (`Application(services:)` on
    /// Hummingbird/Vapor, a `ServiceGroup` on the proposal server). Context-free — `any Service`
    /// carries no request context — so it collates the way controllers do. A `@Singleton`/`@Provides`
    /// binding fans into it via `@Contributes(to: WireMVCKeys.services)`, or the `@BackgroundService`
    /// sugar below.
    public static let services = CollectedKey<any Service>()
}

/// Marks a binding as a `ServiceLifecycle.Service` collated into the graph's services. Adds the
/// `Service` conformance if absent (the type still writes its own `run()`) and aliases
/// `@Contributes(to: WireMVCKeys.services)` — so `@Singleton @BackgroundService` is all a service
/// needs. Parallels `@Controller`.
@attached(extension, conformances: Service)
public macro BackgroundService() =
    #externalMacro(module: "WireMVCMacros", type: "BackgroundServiceMacro")

/// Tells Wire that `@BackgroundService` aliases `@Contributes(to: WireMVCKeys.services)`, so a service
/// needs only `@Singleton @BackgroundService` — the plugin collates it without a separate
/// `@Contributes`.
public let wireMVCServiceAlias = WireAdapterAnnotationV1(
    annotation: "BackgroundService",
    contributesTo: WireMVCKeys.services
)
