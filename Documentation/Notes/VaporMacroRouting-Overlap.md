# Prior art: Vapor's `@Controller` macro routing (relation to WireMVC / M5)

Notes on Vapor's macro-based routing, for the M5 writeup's "related work" section.
The aim is to record **how the two approaches differ architecturally** and **how
each relates to prior art in the declarative-routing / DI space** — not to critique
an evolving proposal. Vapor's is experimental and early; specifics below may change.

**Source reviewed:** `vapor/vapor` @ `b3ad3ac9` (2026-07-04), the `MacroRouting`
proposal — `Sources/VaporMacros`, `Sources/VaporMacrosPlugin`, and its usage in
`Sources/Development/routes.swift`. The feature is gated behind `#if MacroRouting`
and targets Vapor 5 (early alpha).

## What the Vapor proposal is

Three macros, emitting Vapor-native code (`RoutesBuilder` / `Request` /
`RouteCollection`):

1. **`@Controller`** — an extension macro that generates `boot(routes:)` and
   conforms the type to `RouteCollection`, emitting one `routes.<verb>(path) { ... }`
   per verb-annotated member.

2. **HTTP-verb macros** (`@GET`/`@POST`/`@PUT`/`@DELETE`/`@PATCH`/`@HTTP`) — peer
   macros that generate a `_route_<name>(req: Request)` wrapper: extract path params,
   call the handler, encode the result. (A freestanding variant of each exists for
   use on local functions.)

3. **`@AuthMiddleware(T.self, middleware...)`** — declares an authenticated principal
   parameter and groups middleware onto the route.

### Parameter binding
- **Path params**, matched positionally by type: variadic `Int.self, UUID.self`
  become `:int0`, `:uuid1` and are extracted via `req.parameters.require("int0", as:
  Int.self)`.
- Query, headers, and body are read off `req` directly inside the handler
  (`req.content.decode`, `req.query`, …).
- WireMVC instead exposes `@Path` / `@Query` / `@JSONBody` / `@Header` as markers on
  an extensible `RequestBound` protocol, so those bindings are expressed in the
  handler signature.

## Dependency model: two different centres of gravity

The proposals differ less in "how much DI" and more in **what carries per-request
context**.

- **Vapor centres the `Request`.** Every handler takes `req: Request` first, and
  reaches collaborators through it (`req.application`, `req.db`, `req.auth`). This is
  the well-established *context-object / service-locator* model common to many web
  frameworks (Go's `http.Request`+context, Node's `req`/`res`). The macro layer adds
  one resolved-value injection — `@AuthMiddleware` binds the authenticated principal
  via `req.auth.require(_:)` — but otherwise leaves dependency access to `req`.
- **WireMVC centres a DI container.** `@Inject` properties are resolved from
  swift-wire's graph, and controllers declare a lifecycle (`@Singleton`). This is the
  *compile-time dependency-injection* lineage (closer to Micronaut / Dagger than to
  Spring's runtime-reflection container), with the handler signature as the contract.

Neither is more "correct"; they are different philosophies. Vapor's model doesn't
have a container by design, so container-shaped features (general injection,
resolver scopes) live outside its scope.

## Controller lifecycle / scoping

- **Vapor:** controllers are mounted once (`app.register(collection: UserController())`)
  and shared across requests (the generated wrappers are `@Sendable`), i.e.
  **app-scoped singletons**. Per-request state is carried by the `Request`.
- **WireMVC:** additionally offers **request-scoped controllers** — `@Scoped(seed:)`
  constructs a fresh controller per request (M5.4), alongside `@Singleton` controllers
  in the same app. This maps onto **Spring's bean scopes** (`singleton` vs `request`),
  realised at compile time rather than via a runtime container. It is the capability
  furthest from anything in the Vapor proposal, and a primary reason WireMVC exists as
  a layer rather than staying with framework-native controllers. See
  [swift-wire M5_PLAN.md, Iteration M5.4](https://github.com/tachyonics/swift-wire/blob/main/Documentation/M5_PLAN.md).

## Controller registration

- **Vapor:** each controller is registered explicitly — one
  `app.register(collection:)` per controller. (A per-declaration macro can only see
  the type it is attached to, and Swift has no runtime conformance enumeration, so
  cross-controller aggregation isn't something a `@Controller`-style macro does on its
  own.)
- **WireMVC:** `@Controller` emits a `TransportContributor` witness, and swift-wire's
  M3 `ServerTransport` surface aggregates contributors and drives `transport.register`
  per route. Note WireMVC does not *auto-discover* controllers either (same Swift
  constraints) — the difference is that collation is expressed as a first-class
  surface rather than as per-controller registration calls.

## How each relates to prior art

- **Spring MVC** is the shared archetype for both: annotation-driven controllers
  (`@Controller`, `@GetMapping`, `@PathVariable`, `@RequestBody`) plus a DI container
  with bean scopes. Vapor adopts the *routing-annotation* half; WireMVC adopts both
  the routing-annotation half and the *DI + scopes* half.
- **Compile-time DI (Micronaut / Dagger / Quarkus):** WireMVC's macro-generated
  wiring belongs to this lineage — dependencies resolved at build time, no runtime
  reflection — rather than Spring's classic reflective container.
- **Context-object routing (Go/Node, and Vapor today):** Vapor's `Request`-centric
  handlers continue this model; the macro is sugar over route registration on top of
  it.
- **Hummingbird's result-builder router** is a third point in the Swift-native
  declarative-routing space — a builder DSL rather than annotations — worth citing
  alongside Vapor's macros as parallel ecosystem experiments.
- **Cross-runtime target:** WireMVC binds to swift-wire's `ServerTransport`, so the
  same controller mounts on Hummingbird / Vapor / Lambda; Vapor's macro is
  framework-native by construction. This portability axis has no direct analogue in
  the Vapor proposal.

## Overlap at a glance

Capabilities where both have a genuine equivalent, each read against the prior-art
construct it descends from:

| Capability | Prior-art analogue | Vapor `@Controller` proposal | WireMVC |
|---|---|---|---|
| Controller declaration | Spring `@Controller` / `@RestController` | `@Controller` (→ `RouteCollection`) | `@Controller` (→ `TransportContributor`) |
| HTTP-verb routing | Spring `@GetMapping`; JAX-RS `@GET` + `@Path` | `@GET`/`@POST`/… — verb+path in one annotation (Spring-shaped), uppercase naming (JAX-RS-flavoured) | `@Get`/`@Post`/… — Spring-style naming + path template |
| Path-param binding | Spring `@PathVariable`; JAX-RS `@PathParam` | positional-by-type — unlike either; no named binding | `@Path` marker — aligns with `@PathVariable` |
| Response encoding | Spring `@ResponseBody` + message converters | `ResponseEncodable` / `encodeResponse` — framework content system | `@JSONResponse` / `@ResponseStatus` — aligns with `@ResponseBody` / `@ResponseStatus` |
| Controller registration | Spring component-scan + container | per-controller `app.register(collection:)` — manual, framework-native | `ServerTransport` collation of contributors — container-driven (explicit, not reflective) |
| Auth principal into handler | Spring Security `@AuthenticationPrincipal` | `@AuthMiddleware(User.self)` → `req.auth.require` | request-scoped principal (M5.4) |

**The pattern the column reveals:** each proposal is the natural shape of its host
philosophy. Vapor's rows lean *framework-native* — its own content system, manual
route registration, verb-annotation naming echoing JAX-RS — i.e. what you'd design
for a Vapor-centric declarative layer. WireMVC's rows lean *Spring-DI-native* — named
binding markers, `@ResponseBody`-style response annotations, a container-driven
collation and scope model — i.e. what you'd design for a DI-centric one. Where the
rows are "equivalent," they're equivalent in *intent*; the architecture underneath
follows whichever centre of gravity (§ *Dependency model*) the proposal starts from.

Areas present in WireMVC without a proposal-level equivalent — and their prior art:
`@Query` / `@Header` / `@JSONBody` bindings (Spring `@RequestParam` / `@RequestHeader`
/ `@RequestBody`); `@Inject` / `@Singleton` DI (Spring beans; compile-time via
Micronaut / Dagger); request-scoped controllers (Spring bean scopes); cross-runtime
mounting (no direct Spring/JAX-RS analogue — a Swift-ecosystem concern).
