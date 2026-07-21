public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import WireMVC

/// The batteries-included router for the WireMVC-native (proposal-server) path: a concrete
/// `RoutableHTTPServerBuilder` that is *also* the proposal's `HTTPServerRequestHandler`, so it both
/// collects routes (via `WireMVC.apply`) and serves them (via `server.serve(handler:)`). WireMVC's
/// core stays router-agnostic — it registers onto *any* builder; this is the router a
/// `@WireMVCBootstrap` composition root's `createRoutableBuilder(for:)` returns when it doesn't bring
/// its own. Generic over the server's associated types (the one place the `~Copyable` streaming
/// machinery is threaded); the routing algorithm lives in the non-generic ``RouteTable``.
///
/// v1: linear-scan matching, first-registered-wins, `{name}` path parameters, `404` on no match.
/// Production hardening is tracked in [Notes/WireMVCRouter.md].
public struct WireRouter<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: HTTPServerRequestHandler, RoutableHTTPServerBuilder
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    private var table = RouteTable()
    private var handlers:
        [@Sendable (
            HTTPRequest,
            consuming RequestContext,
            [String: Substring],
            consuming sending Reader,
            consuming sending ResponseSender
        ) async throws -> Void] = []

    public init() {}

    /// Infer the router's associated types from the server it will serve on, so callers needn't spell
    /// `WireRouter<Server.RequestContext, …>` by hand. The inverse (`~Copyable`) requirements are
    /// restated because they don't propagate across the generic boundary on their own.
    public init<Server: HTTPServer>(for server: borrowing Server)
    where
        Server.RequestContext == RequestContext,
        Server.Reader == Reader,
        Server.ResponseSender == ResponseSender,
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        self.init()
    }

    public mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContext,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    ) {
        let index = table.add(method: method, path: path)
        precondition(index == handlers.count, "RouteTable index and handler array drifted")
        handlers.append(handler)
    }

    public func handle(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender
    ) async throws {
        // Resolve the route and its path parameters up front — no consuming — so the reader and
        // sender are consumed exactly once, on a single path (the matched handler, or the 404).
        guard let matched = table.resolve(method: request.method, path: request.path ?? "/") else {
            try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
            return
        }
        try await handlers[matched.index](request, requestContext, matched.parameters, reader, responseSender)
    }
}
