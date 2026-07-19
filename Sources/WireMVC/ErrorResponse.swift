// The runtime the generated terminal `catch` folds an `@ErrorResponse` chain onto. Each entry is one
// `wireMVCRespond` call — a typed mapping consulted in order, returning `nil` to fall through to the
// next — with `wireMVCRespondAny` as the `Swift.Error` catch-all (always matches, non-optional). Both
// are declared `throws` (not `rethrows`) so the generated `try` over the whole chain is always valid,
// whether or not a given mapping actually throws — the codegen doesn't need to read each mapping's
// effects. A mapping's own throw propagates out to the framework like any other unmapped error.
// See Notes/RouteErrorHandling.md.

/// Apply a typed error mapping if the thrown error is an `E`, else `nil` (fall through). The mapping is a
/// static `(E) throws -> WireMVCOutcome` — a referenced method or an inline closure; `E` is inferred from
/// it, so the generated call is just `wireMVCRespond(to: error, <mapping>)`.
public func wireMVCRespond<E: Error>(
    to error: any Error,
    _ respond: (E) throws -> WireMVCOutcome
) throws -> WireMVCOutcome? {
    guard let typed = error as? E else { return nil }
    return try respond(typed)
}

/// The `Swift.Error` catch-all — always matches, so it needs no cast and yields a non-optional outcome
/// (the terminal of the chain). A separate name (not an `E == any Error` overload) keeps the generated
/// call unambiguous.
public func wireMVCRespondAny(
    to error: any Error,
    _ respond: (any Error) throws -> WireMVCOutcome
) throws -> WireMVCOutcome {
    try respond(error)
}
