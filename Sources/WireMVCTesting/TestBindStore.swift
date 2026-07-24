public import Foundation
import Synchronization

// The doubles-supply channel for a `@WireMVCBootstrap` app under real HTTP. The test drives the server
// over the loopback boundary, so the only per-request channel is the request itself: `withBindValues`
// registers the test's concrete doubles in an in-process store under a freshly minted `CorrelationID`,
// binds that id to a task-local, and `TestClient` stamps it on the `X-WireMVC-Test-Binds` header of every
// request inside the closure. The request dispatch (generated, H2) reads the header back, pulls the
// doubles from the store, and threads them into the variant scope-entry. The store holds the CONCRETE
// `_<Key>Doubles` through its type parameter — no boxing, no downcast.

/// Correlates a `withBindValues` closure with the requests it drives: minted per closure, carried on the
/// task-local, stamped on the request header, and used to key the store slot holding that closure's doubles.
public struct CorrelationID: Sendable, Hashable {
    /// The underlying identity, rendered onto the request header as its UUID string.
    public let rawValue: UUID

    /// Wrap an existing UUID — used by ``correlationID(fromHeaderValue:)`` when parsing the header back.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// A fresh, unique correlation id for one `withBindValues` closure.
    public static func mint() -> CorrelationID {
        CorrelationID(rawValue: UUID())
    }
}

/// The per-key doubles store: a `Mutex`-guarded map from a request's ``CorrelationID`` to the concrete
/// `Doubles` the test supplied for it. A framework generic instantiated per `TestingKey` as a generated
/// static (the generated `_<Key>Doubles` is `Sendable`), so `withBindValues` and the request dispatch share
/// the exact stored type — the dispatch reads it back concretely and hands it straight to the scope-entry.
public final class TestBindStore<Doubles: Sendable>: Sendable {
    private let slots = Mutex<[CorrelationID: Doubles]>([:])

    /// A new, empty store — one per key, held as a generated static.
    public init() {}

    /// Register `doubles` under `id`, replacing any existing slot for it.
    public func put(_ doubles: Doubles, for id: CorrelationID) {
        slots.withLock { $0[id] = doubles }
    }

    /// The doubles registered for `id`, or `nil` if none — a non-removing read, so the dispatch can read
    /// once per request while the closure keeps the slot alive until it exits.
    public func value(for id: CorrelationID) -> Doubles? {
        slots.withLock { $0[id] }
    }

    /// Drop `id`'s slot — called from `withBindValues`'s `defer` on the way out.
    public func remove(_ id: CorrelationID) {
        slots.withLock { _ = $0.removeValue(forKey: id) }
    }
}

/// The request header carrying a request's ``CorrelationID`` from `TestClient` to the dispatch. Never
/// emitted in production — only `TestClient`, inside a `withBindValues` closure, stamps it.
public let wireMVCTestBindsHeader = "X-WireMVC-Test-Binds"

/// Parse a ``CorrelationID`` from a raw `X-WireMVC-Test-Binds` header value, or `nil` if it isn't a valid
/// id — the dispatch side (H2) uses this to look the request's doubles up in the store.
public func correlationID(fromHeaderValue value: String) -> CorrelationID? {
    UUID(uuidString: value).map(CorrelationID.init(rawValue:))
}

extension WireMVCTesting {
    /// Carries the current `withBindValues` closure's ``CorrelationID`` down its task tree; `TestClient`
    /// reads it to stamp the request header. `nil` outside a `withBindValues` closure, so requests driven
    /// there carry no header.
    @TaskLocal public static var currentCorrelationID: CorrelationID?

    /// The framework core the generated per-key `withBindValues` wrapper calls: mint a ``CorrelationID``,
    /// register `doubles` under it in `store`, bind it to the task-local for the duration of `body`, and
    /// drop the store slot on exit (`defer` — survives throws/cancellation; a crashed process drops the
    /// whole store). The generated wrapper builds the concrete `_<Key>Doubles` from its per-slot parameters
    /// and passes it here, so the store's type parameter is that exact type — no boxing.
    public static func withBindValues<Doubles: Sendable, R>(
        _ doubles: Doubles,
        in store: TestBindStore<Doubles>,
        _ body: () async throws -> R
    ) async throws -> R {
        let id = CorrelationID.mint()
        store.put(doubles, for: id)
        defer { store.remove(id) }
        return try await $currentCorrelationID.withValue(id) {
            try await body()
        }
    }
}
