import Wire
import WireMVC

// One app-scoped controller. `@Singleton @Controller` is all it needs — WireMVC collates it and the
// generated `@main` registers it. `GET /hello/{name}` → `{"message":"Hello, {name}!"}`.

@Singleton
@Controller("/hello")
struct HelloController {
    @Inject let greeter: Greeter

    @Get("/{name}")
    @JSONResponse
    func hello(@Path name: String) -> Greeting {
        Greeting(message: greeter.greet(name))
    }

    // M5.5 Phase 3: this controller declares no `@ErrorResponse`, so `TenantMissing` is unmapped here.
    // The `@WireMVCBootstrap` composition root's global `@ErrorResponse(TenantMissing.self, .badRequest)`
    // is the default tier folded into this route's terminal — so `GET /hello/tenant` returns 400.
    @Get("/tenant")
    @JSONResponse
    func tenant() throws -> Greeting {
        throw TenantMissing()
    }
}

struct Greeting: Codable, Sendable {
    let message: String
}

struct TenantMissing: Error {}
