import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// Proof that `@Replaces` swaps a re-composed app binding for a test double. This target re-composes the
// app's graph via its own `WireMVCBuildPlugin` (the app carries `_WireExports.swift`), and its
// `@Replaces FakeGreeter` supersedes the app's `RealGreeter`. The generated `.wiremvc()` suite trait serves
// that fake graph on an ephemeral port; `GET /hello/Alice` returns the fake's response. `@Replaces` carries
// no `TestingKey`, so the keyless `.wiremvc()` serving the replaced graph is exactly right here.

@Suite(.wiremvc())
struct ReplaceTests {
    /// `GET /hello/{name}` routes through the graph-constructed `HelloController`, whose injected `Greeter`
    /// resolves to the target's `@Replaces` `FakeGreeter` — so the body is `FAKE:Alice`, not the real
    /// `Hello, Alice!`. This is the whole point: the app's real binding was superseded by the test double.
    @Test func serveHelloUsesReplacedFakeGreeter() async throws {
        let response = try await TestClient.current.get("/hello/Alice")
        #expect(response.status == 200)
        let greeting = try response.json(Greeting.self)
        #expect(greeting.message == "FAKE:Alice")
        #expect(greeting.message != "Hello, Alice!")
    }
}
