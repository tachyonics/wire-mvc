# wire-mvc

`WireMVC` — a cross-runtime, declarative-routing [swift-wire](https://github.com/tachyonics/swift-wire)
adapter. Controllers are written with `@Controller` / HTTP-verb / parameter / response
annotations, and the `@Controller` macro generates their route registration onto a
`some ServerTransport` (swift-wire's M3 collation surface). Because the target is
`ServerTransport` — and the package depends only on `OpenAPIRuntime`, no HTTP framework — the
same controller mounts on Hummingbird, Vapor, or Lambda unchanged.

```swift
@Singleton
@Controller("/users")
struct UsersController {
    @Inject var repository: UserRepository

    @Get("/{id}")
    @JSONResponse
    func getUser(@Path id: String) async throws -> User { try repository.find(id) }

    @Post
    @JSONResponse(status: .created)
    func create(@JSONBody new: NewUser) async throws -> User { repository.insert(new) }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    func delete(@Path id: String) async throws { try repository.remove(id) }
}
```

The `@Controller` macro walks the routes and generates a `TransportContributor` witness — one
`transport.register` per route: decode the parameters, call the handler, encode the response.
Parameter bindings (`@Path` / `@Query` / `@JSONBody` / `@Header`) are property-wrapper markers
that host their extraction on a `RequestBound` protocol, so the macro stays a thin dispatcher
and bindings are user-extensible. See
[swift-wire's WireMVCDesign.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/WireMVCDesign.md)
for the full design and [M5_PLAN.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/M5_PLAN.md)
for the milestone.

## Status

Under construction (M5.1). This first cut is **self-contained** — it proves the macro and the
generated `ServerTransport` witness end-to-end, without the swift-wire graph collation yet.

- **M5.1a** — the member-walking `@Controller` macro + the `RequestBound` bindings + the
  generated witness, served through a `ServerTransport` in `WireMVCExample`. **Current.**
- **M5.1b** — swift-wire graph integration: `@Singleton` + the `@Contributes` alias +
  `TransportComposable` conformance + `Wire.bootstrap()` + `WireMVC.apply`.
- **M5.1c** — example ports (`hello`, `todos`) + live cross-runtime on Hummingbird + Vapor.
- **M5.1d** — extract the shared `ServerTransport` collation surface so WireMVC and WireOpenAPI
  fold into one key (migrating wire-open-api onto it).

Validated on macOS and Linux (see CI).
