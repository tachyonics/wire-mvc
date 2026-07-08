import HTTPTypes
import OpenAPIRuntime

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// End-to-end: `@Controller` generated `UsersController.registerWireHandlers(on:)`; we register
// onto a transport and drive real requests through the generated witnesses.

struct ExampleFailed: Error {}

var failed = false
@MainActor
func expect(_ condition: Bool, _ label: String) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
    if !condition { failed = true }
}

let transport = DispatchingTransport()
try UsersController().registerWireHandlers(on: transport)

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

// @Get @JSONResponse — @Query default/override + optional @Query/@Header
do {
    // No query, no header: defaulted @Query (limit=10), optional @Query/@Header absent → nil, no 400.
    let (defaulted, body) = try await transport.send(.get, "/users")
    let count = try JSONDecoder().decode([User].self, from: Data(body)).count
    expect(
        defaulted.status == .ok && count == 10,
        "GET /users  → 200, @Query default (10) + optional @Query/@Header absent"
    )

    // Override the defaulted @Query, and supply the optional @Header.
    let (overridden, body2) = try await transport.send(.get, "/users?limit=3", headers: ["x-trace": "abc"])
    let count2 = try JSONDecoder().decode([User].self, from: Data(body2)).count
    expect(overridden.status == .ok && count2 == 3, "GET /users?limit=3 (+x-trace)  → 200, @Query override")
}

if failed {
    print("wire-mvc example FAILED")
    throw ExampleFailed()
}
print("wire-mvc example OK — @Controller generated the ServerTransport witnesses and served every route")
