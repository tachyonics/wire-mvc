import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// End-to-end through the graph: `Wire.bootstrap()` builds the graph (constructing `UserStore`
// and injecting it into the collated `UsersController`); `WireMVC.apply` registers the
// controller's generated routes onto a transport, which we then drive with real requests.

struct ExampleFailed: Error {}

var failed = false
@MainActor
func expect(_ condition: Bool, _ label: String) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
    if !condition { failed = true }
}

let graph = try await Wire.bootstrap()
let transport = DispatchingTransport()
try WireMVC.apply(graph, to: transport)

// @Get("/{id}") @JSONResponse — @Path decode, 200, JSON body
do {
    let (response, body) = try await transport.send(.get, "/users/42")
    let user = try JSONDecoder().decode(User.self, from: Data(body))
    expect(
        response.status == .ok && user == User(id: "42", name: "Ada"),
        "GET /users/42  → 200, @Path decoded, JSON body"
    )
}

// @Post @JSONResponse(status: .created) @JSONBody — 201, JSON in/out
do {
    let (response, body) = try await transport.send(
        .post,
        "/users",
        contentType: "application/json",
        body: HTTPBody(#"{"name":"Grace"}"#)
    )
    let user = try JSONDecoder().decode(User.self, from: Data(body))
    expect(
        response.status == .created && user.name == "Grace",
        "POST /users  → 201, @JSONBody decoded, @JSONResponse(status:)"
    )
}

// @Delete("/{id}") @ResponseStatus(.noContent) — 204, no body
do {
    let (response, body) = try await transport.send(.delete, "/users/42")
    expect(
        response.status == .noContent && body.isEmpty,
        "DELETE /users/42  → 204, @ResponseStatus, empty body"
    )
}

// @JSONBody content-type rules
do {
    let (wrong, _) = try await transport.send(.post, "/users", contentType: "text/plain", body: HTTPBody("nope"))
    expect(wrong.status == .unsupportedMediaType, "POST wrong Content-Type  → 415")

    let (bad, _) = try await transport.send(.post, "/users", contentType: "application/json", body: HTTPBody("{bad"))
    expect(bad.status == .unprocessableContent, "POST malformed JSON  → 422")

    let (lenient, _) = try await transport.send(.post, "/users", contentType: nil, body: HTTPBody(#"{"name":"Ada"}"#))
    expect(lenient.status == .created, "POST missing Content-Type  → lenient decode → 201")
}

// @Get @JSONResponse — @Query default/override + optional @Query/@Header, present and absent
do {
    // Nothing supplied: defaulted @Query (limit=10); optional @Query/@Header absent → nil.
    let (defaulted, body) = try await transport.send(.get, "/users")
    let listing = try JSONDecoder().decode(Listing.self, from: Data(body))
    expect(
        defaulted.status == .ok && listing.limit == 10 && listing.cursor == nil && listing.trace == nil
            && listing.users.count == 10,
        "GET /users  → 200, @Query default (10), optional @Query/@Header absent → nil"
    )

    // All supplied: overridden @Query, and the optional @Query + @Header actually bound.
    let (supplied, body2) = try await transport.send(
        .get,
        "/users?limit=3&cursor=c1",
        headers: ["x-trace": "abc"]
    )
    let listing2 = try JSONDecoder().decode(Listing.self, from: Data(body2))
    expect(
        supplied.status == .ok && listing2.limit == 3 && listing2.cursor == "c1" && listing2.trace == "abc"
            && listing2.users.count == 3,
        "GET /users?limit=3&cursor=c1 (+x-trace)  → 200, @Query override + optional @Query/@Header received"
    )
}

if failed {
    print("wire-mvc example FAILED")
    throw ExampleFailed()
}
print("wire-mvc example OK — @Controller generated the ServerTransport witnesses and served every route")
