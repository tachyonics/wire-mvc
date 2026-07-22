/// A value held in a disconnected isolation region, so it survives storage as a `sending` value.
///
/// This is the stable-feature subset of the standard library's `Disconnected<Value>`
/// ([SE-0538](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md),
/// stdlib PR swiftlang/swift#89597), vendored while that type is unshipped. It rides only features present
/// today — noncopyable generics, `sending`, `nonisolated(unsafe)` — so the `@available(SwiftStdlib …)` and
/// `@safe`/emission attributes the stdlib carries are dropped here. Replace this with the stdlib type once
/// it ships (see WireMVCMiddleware.md).
///
/// The whole mechanism is the `nonisolated(unsafe)` storage: it opts the linear value out of region
/// tracking so `consume _value` can be returned `sending`. It is a *safe* abstraction despite the unsafe
/// storage — the only way in is `init(_:)`, which admits a `sending` (already-disconnected) value, and the
/// only way out is the `consuming` `take()`, so the stored value is never aliased. WireMVC uses it inside
/// ``RequestResponseMiddlewareBox`` so the box's linear `Reader`/`ResponseSender` survive extraction as
/// `sending` — which is what lets a folded terminal hand them to another `HTTPServerRequestHandler` (the
/// front-layer global-middleware wrapper's call to `router.handle`).
struct WireDisconnected<Value: ~Copyable>: ~Copyable, Sendable {
    nonisolated(unsafe) var wrapped: Value

    /// Wrap an already-disconnected (`sending`) value.
    init(_ value: consuming sending Value) {
        self.wrapped = value
    }

    /// Consume the wrapper, handing the value back out as `sending` (still disconnected).
    consuming func take() -> sending Value {
        let value = consume wrapped
        return value
    }
}
