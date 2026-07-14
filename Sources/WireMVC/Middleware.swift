public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware

/// The box a middleware chain carries as its `Middleware.Input`/`NextInput`. It is a two-state value:
/// `pending` holds the handler inputs (a fixed request, the per-request `RequestContext`, the request
/// `Reader`) plus the one-shot `ResponseSender`; `responded` means a middleware already wrote the
/// response — the sender is consumed and gone, and only the request is kept so always-run observe
/// middleware can still read it.
///
/// This shape is a *consequence* of the proposal's `Middleware.intercept<Return>(input:next:) -> Return`:
/// the only value of type `Return` is what `next` produces, so every middleware must call `next` (no
/// control-flow short-circuit). A middleware that wants to respond therefore does so by *writing* via
/// the sender and moving the box to `responded`, and the whole chain still runs — the terminal simply
/// skips the handler when the box is already `responded`. Changing that (letting inner middleware be
/// skipped) would require changing the middleware *shape*, not this box. See Notes/WireMVCMiddleware.md.
///
/// It is WireMVC-owned (the proposal ships its own box only in a test module, referenced by nothing and
/// pulling the whole NIO server stack); the middleware themselves stay the proposal's `Middleware`.
public enum RequestResponseMiddlewareBox<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    ResponseSender: HTTPResponseSender & ~Copyable
>: ~Copyable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    /// Still to be handled: the handler inputs and the one-shot sender.
    case pending(request: HTTPRequest, requestContext: RequestContext, reader: Reader, responseSender: ResponseSender)
    /// A middleware has written the response; the sender is consumed. The request is kept for observation.
    case responded(request: HTTPRequest)

    /// A borrowing peek at the request — readable in either state — so a middleware can inspect it
    /// without consuming the box (it still has to pass the box to `next`).
    public var peekedRequest: HTTPRequest {
        switch self {
        case .pending(let request, _, _, _): return request
        case .responded(let request): return request
        }
    }

    /// Whether the request is still to be handled (no middleware has responded yet).
    public var isPending: Bool {
        switch self {
        case .pending: return true
        case .responded: return false
        }
    }

    /// A middleware "handles" the request: `write` is handed the sender (consuming it) to write the
    /// response, and the box becomes `responded`. If the box is already `responded`, it is returned
    /// unchanged — first-decision-wins, enforced by there being no sender to hand over.
    public consuming func responding(
        _ write: nonisolated(nonsending) (consuming ResponseSender) async throws -> Void
    ) async throws -> Self {
        switch consume self {
        case .pending(let request, _, _, let responseSender):
            try await write(responseSender)
            return .responded(request: request)
        case .responded(let request):
            return .responded(request: request)
        }
    }

    /// The generated terminal's destructure: run `handler` with the pending contents, or do nothing if
    /// a middleware already responded.
    public consuming func withPendingContents(
        _ handler:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                consuming Reader,
                consuming ResponseSender
            ) async throws -> Void
    ) async throws {
        switch consume self {
        case .pending(let request, let requestContext, let reader, let responseSender):
            try await handler(request, requestContext, reader, responseSender)
        case .responded:
            break
        }
    }
}

@available(*, unavailable)
extension RequestResponseMiddlewareBox: Sendable {}

/// Builds a route's middleware chain into a *concrete* composed `Middleware` (the `MiddlewareBuilder`
/// fold's inferred `ChainedMiddleware…` type), rather than erasing to `some Middleware`. Returning the
/// concrete type keeps the fold's final box type inferred, which is what lets the terminal call
/// `withPendingContents` on it — a `some Middleware<Input>`-with-pinned-input boundary is not expressible
/// (`Middleware` has two primary associated types), so the fold must stay witness-local and concrete.
/// The generated `registerWireRoutes` witness calls this inline with the route's middleware.
public func wireCompose<Composed: Middleware>(
    @MiddlewareBuilder _ build: () -> Composed
) -> Composed where Composed.Input: ~Copyable, Composed.NextInput: ~Copyable {
    build()
}
