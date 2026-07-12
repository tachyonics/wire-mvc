public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes

/// The registration surface `@Controller`'s generated witness targets, and what `WireMVC.apply`
/// registers onto. It keeps the server's associated `RequestContext`/`Reader`/`ResponseSender` (they
/// must match the server's, per `HTTPServer.serve`'s `Handler.Reader == Reader`), so it is never
/// boxed as `any`. WireMVC stays router-agnostic — it depends only on this protocol; a concrete
/// builder (also an `HTTPServerRequestHandler`, so it can serve) is supplied by the caller.
public protocol RoutableHTTPServerBuilder<RequestContext, Reader, ResponseSender> {
    associatedtype RequestContext: HTTPServerCapability.RequestContext, ~Copyable
    associatedtype Reader: AsyncReader, ~Copyable, SendableMetatype
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?
    associatedtype ResponseSender: HTTPResponseSender, ~Copyable, SendableMetatype
    where ResponseSender.Writer: ~Copyable

    /// Register one route. `handler` receives the request, the matched path parameters, the request
    /// body reader, and the response sender. WireMVC owns this shape: the proposal's handler
    /// signature has no slot for matched path parameters, so the router extracts them from the
    /// path template and passes them in.
    mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    )
}
