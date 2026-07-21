import Wire

// The graph's plain bindings. `@Singleton` makes each a node `Wire.bootstrap()` constructs and
// injects — the controller injects `Greeter`, the composition root injects `ServerConfig`.

/// A binding the controller injects — proves the controller is graph-constructed.
@Singleton
struct Greeter: Sendable {
    func greet(_ name: String) -> String { "Hello, \(name)!" }
}

/// Config the composition root injects — proves `@Inject` on the `@WireMVCBootstrap` type resolves.
@Singleton
struct ServerConfig: Sendable {
    let host = "127.0.0.1"
    let port = 8080
}
