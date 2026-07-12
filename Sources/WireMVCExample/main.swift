import Logging
import NIOHTTPServer
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
// `WireMVC.router` turns the collated controllers into the server's request handler; `NIOHTTPServer`
// serves it on an ephemeral loopback port, which we then drive with real HTTP requests.

struct ExampleFailed: Error {}

// Unbuffered stdout so the per-check lines survive a failing run's `throw`.
setvbuf(stdout, nil, _IONBF, 0)

// Top-level code runs serially on the main actor, so a single counter is safe to mutate directly.
nonisolated(unsafe) var failures = 0

func expect(_ condition: Bool, _ label: String) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
    if !condition { failures += 1 }
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

var router = try WireMVC.router(for: graph, server: server)
try WireMVC.mountIntrospection(for: graph, into: &router)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await server.serve(handler: router) }

    let addresses = try await server.listeningAddresses
    guard let port = addresses.first?.port else { throw ExampleFailed() }

    // @Get("/{id}") @JSONResponse — @Path decode, 200, JSON body
    do {
        let (status, body) = try await send("GET", "/users/42", port: port)
        let user = try JSONDecoder().decode(User.self, from: body)
        expect(
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
        expect(
            status == 201 && user.name == "Grace",
            "POST /users  → 201, @JSONBody decoded, @JSONResponse(status:)"
        )
    }

    // @Delete("/{id}") @ResponseStatus(.noContent) — 204, no body
    do {
        let (status, body) = try await send("DELETE", "/users/42", port: port)
        expect(status == 204 && body.isEmpty, "DELETE /users/42  → 204, @ResponseStatus, empty body")
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
        expect(wrong == 415, "POST wrong Content-Type  → 415")

        let (bad, _) = try await send(
            "POST",
            "/users",
            port: port,
            contentType: "application/json",
            body: Data("{bad".utf8)
        )
        expect(bad == 422, "POST malformed JSON  → 422")
    }

    // @Get @JSONResponse — @Query default/override + optional @Query/@Header, present and absent
    do {
        let (status, body) = try await send("GET", "/users", port: port)
        let listing = try JSONDecoder().decode(Listing.self, from: body)
        expect(
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
        expect(
            status2 == 200 && listing2.limit == 3 && listing2.cursor == "c1" && listing2.trace == "abc"
                && listing2.users.count == 3,
            "GET /users?limit=3&cursor=c1 (+x-trace)  → 200, @Query override + optional @Query/@Header received"
        )
    }

    // WireMVC.mountIntrospection — the graph's wiring model, served over the same router.
    do {
        let (status, body) = try await send("GET", "/wiring", port: port)
        let model = try JSONDecoder().decode(WiringModel.self, from: body)
        expect(
            status == 200 && model.bindings.contains { $0.type.contains("UsersController") },
            "GET /wiring  → 200, WiringModel lists the collated UsersController"
        )
    }

    group.cancelAll()
}

if failures > 0 {
    print("wire-mvc example FAILED")
    throw ExampleFailed()
}
print(
    "wire-mvc example OK — @Controller generated the RouteContributor witnesses and served every route on NIOHTTPServer"
)
