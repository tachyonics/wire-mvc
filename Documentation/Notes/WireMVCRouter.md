# WireMVCRouter — the native-path router (v1 + hardening backlog)

> **Status:** v1 shipped (promoted from example infra), production hardening tracked below. The
> batteries-included router for the WireMVC-native (proposal-server) path, so a `@WireMVCBootstrap`
> composition root's `createRoutableBuilder(for:)` has an obvious thing to return. Opt-in target
> (`WireMVCRouter`) — the WireMVC core stays router-agnostic (it registers onto *any*
> `RoutableHTTPServerBuilder`), and the `ServerTransport` adapter path uses the host framework's router.

## Why it exists

`@WireMVCBootstrap` asks the app for `createRoutableBuilder(for:) -> some RoutableHTTPServerBuilder<…>
& HTTPServerRequestHandler`, but the proposal ships no router (it provides the server + the handler
protocol; routing is the framework's job). Without a provided router, every native-path app would
hand-roll or copy one — both examples did. `WireMVCRouter` fills that gap. The `& HTTPServerRequestHandler`
is load-bearing: `WireMVC.apply` registers routes onto the builder, and `server.serve(handler:)` needs
the *same* value to be a handler.

## Design

- **`RouteTable`** (non-generic, internal) — the routing algorithm, factored out so it is testable
  without the proposal's `~Copyable` request/response machinery. Maps `(method, path template)` → a
  registration index; `resolve(method:path:)` returns the first matching index + bound path parameters.
  Covered by `WireMVCRouterTests`.
- **`WireRouter<RequestContext, Reader, ResponseSender>`** (public, generic) — a `RoutableHTTPServerBuilder`
  *and* `HTTPServerRequestHandler`. Holds a `RouteTable` plus a parallel handler array; `register` appends
  to both, `handle` resolves via the table and dispatches (or answers `404`). Generic over the server's
  associated types (`init(for:)` infers them, mirroring the pattern `WireMVC.apply` uses).

## v1 semantics (what the tests pin)

Linear scan, **first-registered-wins**, `{name}` path parameters, query string stripped before matching,
exact segment-count match, `404` on no match. Empty path segments are omitted, so `/users/` and `/users`
are equivalent (no trailing-slash policy yet).

## Production hardening backlog

Ordered roughly by value; each is additive over v1 and testable through `RouteTable` first.

1. **Radix/trie matching.** Replace the linear scan (`O(routes × segments)`) with a radix tree
   (`O(path length)`). The dominant scalability item; `RouteTable`'s API (`add` → index, `resolve` →
   index + params) is deliberately shaped to swap the internals without touching `WireRouter`.
2. **405 vs 404.** Today any non-match is `404`. Distinguish "a path matched but not this method" →
   **`405 Method Not Allowed` with an `Allow` header** listing the methods that *do* match, from "no
   path matched" → `404`. `resolve` needs to report path-matched-method-mismatched separately.
3. **Route precedence.** Static segments should beat parameters should beat catch-alls
   (`/users/me` before `/users/{id}`), independent of registration order — replacing first-wins.
4. **Catch-all / wildcard params.** `{path*}` capturing the remainder of the path (proxying, static
   file serving).
5. **Trailing-slash policy.** A deliberate choice (strict / redirect / lenient) instead of the
   incidental "empty segments omitted" behavior.
6. **Duplicate-route diagnostics.** Two registrations for the same method+template is almost always a
   bug — surface it (a precondition today only guards index/handler drift).
7. **Percent-decoding** of path parameters (`/users/a%20b` → `a b`).
8. **`registerNotFound` fallback slot.** The seam M5.5 Phase 4 needs for the synthetic fallback route
   (see [../../../swift-wire/Documentation/M5_5_PLAN.md]) — a configurable not-found handler on the
   builder, mapping to the router's `404` path. Lands with Phase 4.

## Relationship to M5.5 phases

- **Phase 4** adds `registerNotFound` here (item 8) + the synthetic fallback route.
- **Phase 5** (global middleware fold) wraps the router's dispatch; the fold hook lives at the
  serve/assembly layer, but the router is where the matched-vs-synthetic-route decision is made.
