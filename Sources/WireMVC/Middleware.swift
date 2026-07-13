public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware

/// The box a middleware chain carries as its `Middleware.Input`/`NextInput` — a fixed request plus the
/// server's per-request `RequestContext`, request `Reader`, and `ResponseSender`. Middleware transform
/// it (`Input → NextInput`, typically enriching the capability-typed `RequestContext`); the generated
/// route terminal explodes the folded final box via `withContents` and projects the handler's params
/// off it.
///
/// It is structurally the proposal's `RequestResponseMiddlewareBox`, but WireMVC-owned: the proposal
/// ships that type only in its `HTTPClientConformance` test module (referenced by nothing, and pulling
/// the whole NIO server stack), so it is not a viable runtime dependency for this framework-agnostic
/// core. The middleware themselves stay the proposal's `Middleware`; only this `Input`/`NextInput` box
/// is ours.
public struct RequestResponseMiddlewareBox<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    ResponseSender: HTTPResponseSender & ~Copyable
>: ~Copyable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    private let request: HTTPRequest
    private let requestContext: RequestContext
    private let reader: Reader
    private let responseSender: ResponseSender

    public init(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming Reader,
        responseSender: consuming ResponseSender
    ) {
        self.request = request
        self.requestContext = requestContext
        self.reader = reader
        self.responseSender = responseSender
    }

    /// The one-shot consuming destructure the generated terminal calls to reach the boxed values. `T`
    /// is `~Copyable` — unlike the proposal's test-module box (`<T>`) — because a middleware that
    /// destructures inside its `intercept` returns the chain's `~Copyable` `Return`.
    public consuming func withContents<T: ~Copyable>(
        _ handler:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                consuming Reader,
                consuming ResponseSender
            ) async throws -> T
    ) async throws -> T {
        try await handler(self.request, self.requestContext, self.reader, self.responseSender)
    }
}

@available(*, unavailable)
extension RequestResponseMiddlewareBox: Sendable {}

/// Builds a route's middleware chain into a *concrete* composed `Middleware` (the `MiddlewareBuilder`
/// fold's inferred `ChainedMiddleware…` type), rather than erasing to `some Middleware`. Returning the
/// concrete type keeps the fold's final box type inferred, which is what lets the terminal call
/// `withContents` on it — a `some Middleware<Input>`-with-pinned-input boundary is not expressible
/// (`Middleware` has two primary associated types), so the fold must stay witness-local and concrete.
/// The generated `registerWireRoutes` witness calls this inline with the route's middleware.
public func wireCompose<Composed: Middleware>(
    @MiddlewareBuilder _ build: () -> Composed
) -> Composed where Composed.Input: ~Copyable, Composed.NextInput: ~Copyable {
    build()
}
