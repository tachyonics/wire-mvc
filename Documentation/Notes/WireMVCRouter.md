# WireMVCRouter — the native-path router (ported trie + hardening backlog)

> **Status:** shipped — a faithful port of `wire-mvc-examples`' `TrieRouteBuilder`/`FrozenTrieRouter`,
> refactored around a testable non-generic core. The batteries-included router for the WireMVC-native
> (proposal-server) path, so a `@WireMVCBootstrap` composition root's `createRoutableBuilder(for:)` has
> an obvious thing to return. Opt-in target (`WireMVCRouter`) — the WireMVC core stays router-agnostic
> (it registers onto *any* `RoutableHTTPServerBuilder`), and the `ServerTransport` adapter path uses
> the host framework's router.

## Why it exists

`@WireMVCBootstrap` asks the app for `createRoutableBuilder(for:)`, but the proposal ships no router
(it provides the server + the handler protocol; routing is the framework's job). Without a provided
router, every native-path app would hand-roll or copy one — every example did. `WireMVCRouter` fills
that gap with the trie router already developed in `wire-mvc-examples`.

## The build → freeze → serve lifecycle

The router is a `ServableRoutableHTTPServerBuilder` — the native-path refinement of the core builder
(defined in `WireMVC/Routing.swift`). Registration and serving are **different types**:

- **`TrieRouteBuilder`** (mutable) — the builder `WireMVC.apply` registers routes onto. `finalize()`
  compacts it into the immutable handler.
- **`FrozenTrieRouter`** (immutable) — *is* the proposal's `HTTPServerRequestHandler`; the server serves
  this. Its literal children are segment-sorted arrays (binary search, no per-request hashing).

The generated `@main` (and `WireMVCExample`'s hand-written assembly) do
`apply(&builder) → builder.finalize() → serve(handler:)`. The `finalize()` step is **not** on the
router-agnostic core `RoutableHTTPServerBuilder` — it's on the `ServableRoutableHTTPServerBuilder`
refinement — because the `ServerTransport` adapter's `ServerTransportRouteBuilder`
(`WireMVCServerTransport.swift:207`) also conforms to the core protocol but doesn't serve via
`HTTPServerRequestHandler`; forcing `finalize() -> some HTTPServerRequestHandler` on it would be a
meaningless conformance.

## Design

- **`RouteTrie` → `FrozenRouteTrie`** (non-generic, internal) — the trie algorithm, factored out so it
  is testable without the proposal's `~Copyable` request/response machinery. `RouteTrie.insert` walks a
  flat node array (literal children in a dictionary, one parameter edge per node) and returns a route
  index; `freeze()` sorts literal children for binary search; `FrozenRouteTrie.resolve` returns the
  matched route index + bound `{name}` parameters. Covered by `WireMVCRouterTests` (11 tests).
- **`TrieRouteBuilder` / `FrozenTrieRouter`** (public, generic over the server's associated types) —
  wrap the trie with the parallel handler array; `register` inserts + appends, `finalize` freezes +
  pairs, `handle` resolves + dispatches (or answers `404`).

## What ships (what the tests pin)

Segment-trie matching (`O(path length)`), `{name}` path parameters, query stripping, segment-exact
matching, **literal-before-parameter precedence** (`/users/me` beats `/users/{id}`),
first-registered-wins per node for the method match, and binary-searched literal children after freeze.
Empty path segments are omitted, so `/users/` ≡ `/users` (no trailing-slash policy yet).

## Production hardening backlog

The trie port already covers what were items #1 (radix matching) and part of #3 (literal-before-param).
What remains, roughly by value; each is additive and testable through `RouteTrie`/`FrozenRouteTrie` first:

1. **405 vs 404.** Any non-match is `404` today. Distinguish "a path matched but not this method" →
   **`405 Method Not Allowed` + `Allow`** (a node was reached with routes, none for this method) from
   "no path matched" → `404`. `resolve` needs to report the node's available methods on a path hit.
2. **Full precedence.** Literal beats parameter already; add parameter beats catch-all, and make it
   order-independent (replace first-registered-wins among ambiguous routes).
3. **Catch-all / wildcard params.** `{path*}` capturing the remainder (proxying, static files).
4. **Trailing-slash policy.** A deliberate choice (strict / redirect / lenient) instead of the
   incidental "empty segments omitted" behavior.
5. **Duplicate-route diagnostics.** Two registrations for the same method+template — surface it (a
   precondition today only guards index/handler drift).
6. **Percent-decoding** of path parameters (`/users/a%20b` → `a b`).
7. **`registerNotFound` fallback slot.** The seam M5.5 Phase 4 needs for the synthetic fallback route
   (see [../../../swift-wire/Documentation/M5_5_PLAN.md]) — a configurable not-found handler mapping to
   the router's `404` path. Lands with Phase 4.

## Relationship to M5.5 phases

- **Phase 4** adds `registerNotFound` here (item 7) + the synthetic fallback route.
- **Phase 5** (global middleware fold) wraps the router's dispatch; the fold hook lives at the
  serve/assembly layer, but the router is where the matched-vs-synthetic-route decision is made.
