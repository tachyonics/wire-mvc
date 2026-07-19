import Logging
import NIOHTTPServer
import Synchronization  // the middleware probe (Atomic)
import Wire  // WiringModel (for the /wiring check)
import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// End-to-end through the graph, served on a real proposal server: `Wire.bootstrap()` builds the
// graph (constructing `UserStore` and injecting it into the collated `UsersController`);
// `WireMVC.apply` registers the collated controllers onto a `WireRouter`, which `NIOHTTPServer`
// serves on an ephemeral loopback port, which we then drive with real HTTP requests.

/// Thrown on any failed check. Its `description` lists the failures, which the runtime prints to
/// stderr (unbuffered) — so a failing CI run shows exactly what broke without a stdout-flush dance.
struct ExampleFailed: Error, CustomStringConvertible {
    let failures: [String]
    var description: String {
        "wire-mvc example FAILED:\n" + failures.map { "  ✗ \($0)" }.joined(separator: "\n")
    }
}

/// One real HTTP request against the loopback server; returns the status code and body bytes.
func send(
    _ method: String,
    _ path: String,
    port: Int,
    contentType: String? = nil,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
}

let graph = try await Wire.bootstrap()

let server = NIOHTTPServer(
    logger: Logger(label: "WireMVCExample"),
    configuration: try .init(
        bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
        supportedHTTPVersions: [.http1_1],
        transportSecurity: .plaintext
    )
)

var router = WireRouter(for: server)
let services = try WireMVC.apply(graph, to: &router)
try WireMVC.mountIntrospection(for: graph, into: &router)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await server.serve(handler: router) }

    let addresses = try await server.listeningAddresses
    guard let port = addresses.first?.port else {
        throw ExampleFailed(failures: ["server did not bind a listening port"])
    }

    // Records checks; the enclosing task-group body is serial on the main actor, so a local list
    // captured by this nested function needs no synchronization.
    var failed: [String] = []
    func check(_ condition: Bool, _ label: String) {
        print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
        if !condition { failed.append(label) }
    }

    // @Get("/{id}") @JSONResponse — @Path decode, 200, JSON body
    do {
        let (status, body) = try await send("GET", "/users/42", port: port)
        let user = try JSONDecoder().decode(User.self, from: body)
        check(
            status == 200 && user == User(id: "42", name: "Ada"),
            "GET /users/42  → 200, @Path decoded, JSON body"
        )
    }

    // @Post @JSONResponse(status: .created) @JSONBody — 201, JSON in/out
    do {
        let (status, body) = try await send(
            "POST",
            "/users",
            port: port,
            contentType: "application/json",
            body: Data(#"{"name":"Grace"}"#.utf8)
        )
        let user = try JSONDecoder().decode(User.self, from: body)
        check(
            status == 201 && user.name == "Grace",
            "POST /users  → 201, @JSONBody decoded, @JSONResponse(status:)"
        )
    }

    // @Delete("/{id}") @ResponseStatus(.noContent), guarded by the route-scope @Middleware(RequireAdmin).
    // With x-admin the gate forwards and the handler runs → 204.
    do {
        let (status, body) = try await send("DELETE", "/users/42", port: port, headers: ["x-admin": "true"])
        check(status == 204 && body.isEmpty, "DELETE /users/42 (x-admin)  → 204, @ResponseStatus, empty body")
    }

    // Without x-admin the gate handles the request itself — writes 403, the box becomes .responded, and
    // the handler is skipped (Model B short-circuit); the controller-scope middleware still ran.
    do {
        let (status, _) = try await send("DELETE", "/users/99", port: port)
        check(status == 403, "DELETE /users/99 (no x-admin)  → 403, @Middleware gate responded, handler skipped")
    }

    // @JSONBody content-type rules. (The lenient-on-a-genuinely-missing-Content-Type path is a
    // binding-layer detail that a real HTTP client can't exercise — `URLSession` injects a default
    // `Content-Type` for any body — so it's covered by spike-11, not here.)
    do {
        let (wrong, _) = try await send(
            "POST",
            "/users",
            port: port,
            contentType: "text/plain",
            body: Data("nope".utf8)
        )
        check(wrong == 415, "POST wrong Content-Type  → 415")

        let (bad, _) = try await send(
            "POST",
            "/users",
            port: port,
            contentType: "application/json",
            body: Data("{bad".utf8)
        )
        check(bad == 422, "POST malformed JSON  → 422")
    }

    // @Get @JSONResponse — @Query default/override + optional @Query/@Header, present and absent
    do {
        let (status, body) = try await send("GET", "/users", port: port)
        let listing = try JSONDecoder().decode(Listing.self, from: body)
        check(
            status == 200 && listing.limit == 10 && listing.cursor == nil && listing.trace == nil
                && listing.users.count == 10,
            "GET /users  → 200, @Query default (10), optional @Query/@Header absent → nil"
        )

        let (status2, body2) = try await send(
            "GET",
            "/users?limit=3&cursor=c1",
            port: port,
            headers: ["x-trace": "abc"]
        )
        let listing2 = try JSONDecoder().decode(Listing.self, from: body2)
        check(
            status2 == 200 && listing2.limit == 3 && listing2.cursor == "c1" && listing2.trace == "abc"
                && listing2.users.count == 3,
            "GET /users?limit=3&cursor=c1 (+x-trace)  → 200, @Query override + optional @Query/@Header received"
        )
    }

    // @Get("/events/stream") @RawRoute — the raw handler writes the response sender itself (no decode/encode).
    do {
        let (status, body) = try await send("GET", "/users/events/stream", port: port)
        check(
            status == 200 && String(decoding: body, as: UTF8.self) == "data: hello\n\n",
            "GET /users/events/stream  → 200, @RawRoute handler wrote the response sender directly"
        )
    }

    // @Scoped(seed: HTTPRequest.self) @Controller — a request-scoped controller, constructed fresh per
    // request from the request seed (the `_wireEnterScope` bridge thunk), injecting a request-scoped
    // `RequestInfo` alongside the shared `@Singleton` `UserStore`. Two requests see two different
    // request-scoped values (fresh per request); the singleton resolves for both (shared).
    do {
        let (s1, b1) = try await send("GET", "/whoami?who=ada", port: port)
        let (s2, b2) = try await send("GET", "/whoami?who=grace", port: port)
        let w1 = try JSONDecoder().decode(WhoAmI.self, from: b1)
        let w2 = try JSONDecoder().decode(WhoAmI.self, from: b2)
        check(
            s1 == 200 && s2 == 200 && w1.path == "/whoami?who=ada" && w2.path == "/whoami?who=grace"
                && w1.storeShared && w2.storeShared,
            "@Scoped(seed:) @Controller  → request-scoped value fresh per request, @Singleton shared"
        )
    }

    // WireMVC.mountIntrospection — the graph's wiring model, served over the same router.
    do {
        let (status, body) = try await send("GET", "/wiring", port: port)
        let model = try JSONDecoder().decode(WiringModel.self, from: body)
        check(
            status == 200 && model.bindings.contains { $0.type.contains("UsersController") },
            "GET /wiring  → 200, WiringModel lists the collated UsersController"
        )
    }

    // @BackgroundService collation — `WireMVC.apply` returns the graph's collated services, which
    // include the `Heartbeat` contributed by `@BackgroundService` on a `@Provides` function.
    check(
        services.contains { $0 is Heartbeat },
        "@BackgroundService  → apply returns graph.services collating the Heartbeat service"
    )

    // @Middleware(RequestLogMiddleware<…>.self) — controller-scope middleware wrapped every route, so
    // the probe counted once per request served above (all reached the handler through the fold).
    let observedRequests = requestProbe.load(ordering: .relaxed)
    check(
        observedRequests > 0,
        "@Middleware  → controller-scope middleware ran around every route (probe counted \(observedRequests))"
    )

    // @Middleware(AuditMiddlewareKeys.factory) — a generic-with-deps middleware with non-canonical
    // parameter order (<Sender, Reader, Ctx>), mapped by @MiddlewareFactory(.responseSender, .reader,
    // .requestContext). That it ran proves the role-ordered create folded correctly.
    let observedAudits = auditProbe.load(ordering: .relaxed)
    check(
        observedAudits > 0,
        "@MiddlewareFactory  → reordered generic-with-deps middleware folded and ran (probe counted \(observedAudits))"
    )

    group.cancelAll()
    if !failed.isEmpty { throw ExampleFailed(failures: failed) }
}

print(
    "wire-mvc example OK — @Controller generated the RouteContributor witnesses and served every route on NIOHTTPServer"
)
