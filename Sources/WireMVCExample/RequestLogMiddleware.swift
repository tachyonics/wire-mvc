import Synchronization
import WireMVC

/// A global probe the middleware bumps, so the self-test can observe that the middleware ran around the
/// handler. A real logging/metrics middleware would log or record a metric; this records a count.
let requestProbe = Atomic<Int>(0)

/// A non-transforming request middleware, generic over the box (`Input == NextInput`), dep-free. Named
/// in `@Middleware` via the placeholder types — `@Middleware(RequestLogMiddleware<WireContext,
/// WireReader, WireSender>.self)` — which the macro discards, re-spelling over the builder's associated
/// types and constructing it inline.
struct RequestLogMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        requestProbe.add(1, ordering: .relaxed)
        return try await next(input)
    }
}
