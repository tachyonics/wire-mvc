import HTTPTypes
import Wire
import WireMVC

// A request-scoped controller — the M5.4 case. `@Scoped(seed: HTTPRequest.self) @Controller` makes the
// controller a *bridge* proxy: it's constructed fresh per request from the request seed (via the
// plugin-generated `_wireEnterScope` thunk), injecting a request-scoped `RequestInfo` built from that
// same seed, alongside the app-`@Singleton` `UserStore` (shared across every request).

/// A request-scoped value built from the `HTTPRequest` seed — its `path` reflects the request that
/// opened the scope, so two requests see two different instances.
@Scoped(seed: HTTPRequest.self)
struct RequestInfo: Sendable {
    let path: String
    @Inject init(request: HTTPRequest) { self.path = request.path ?? "" }
}

struct WhoAmI: Codable, Sendable {
    let path: String
    let storeShared: Bool
}

@Scoped(seed: HTTPRequest.self)
@Controller("/whoami")
struct WhoAmIController: Sendable {
    @Inject var info: RequestInfo  // request-scoped — fresh per request
    @Inject var store: UserStore  // app singleton — shared

    @Get
    @JSONResponse
    func get() async throws -> WhoAmI {
        WhoAmI(path: info.path, storeShared: (try? store.find("42")) != nil)
    }
}
