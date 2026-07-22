public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import WireMVC

/// The batteries-included router for the WireMVC-native (proposal-server) path — a path-segment trie.
/// Build → freeze → serve: `TrieRouteBuilder` is the mutable `FinalizableHTTPServerRouteBuilder`
/// (`WireMVC.apply` registers routes onto it); `finalize()` compacts it into the immutable
/// `FrozenTrieRouter`, which *is* the proposal's `HTTPServerRequestHandler` the server serves. A
/// `@WireMVCBootstrap` composition root returns this from `createRouteBuilder(for:)`.
///
/// WireMVC's core stays router-agnostic — it registers onto *any* builder; this is the router the
/// native path uses when the app doesn't bring its own. Generic over the server's associated types (the
/// one place the `~Copyable` streaming machinery is threaded); the routing algorithm lives in the
/// non-generic ``RouteTrie``/``FrozenRouteTrie``.
public struct TrieRouteBuilder<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: FinalizableHTTPServerRouteBuilder
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    public typealias Handler =
        @Sendable (
            HTTPRequest,
            consuming RequestContext,
            [String: Substring],
            consuming sending Reader,
            consuming sending ResponseSender
        ) async throws -> Void

    private var trie = RouteTrie()
    private var handlers: [Handler] = []
    /// The fallback dispatched to on an unmatched request (M5.5 Phase 4). `nil` until `registerNotFound`;
    /// the frozen router answers a built-in 404 when it stays `nil`.
    private var notFoundHandler: Handler?

    public init() {}

    /// Infer the router's associated types from the server it will serve on, so callers needn't spell
    /// `TrieRouteBuilder<Server.RequestContext, …>` by hand. The inverse (`~Copyable`) requirements are
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
        handler: @escaping Handler
    ) {
        let index = trie.insert(method: method, path: path)
        precondition(index == handlers.count, "RouteTrie index and handler array drifted")
        handlers.append(handler)
    }

    public mutating func registerNotFound(handler: @escaping Handler) {
        notFoundHandler = handler
    }

    /// Freeze the trie and pair it with the handler array — the immutable handler the server serves.
    public consuming func finalize() -> FrozenTrieRouter<RequestContext, Reader, ResponseSender> {
        FrozenTrieRouter(trie: trie.freeze(), handlers: handlers, notFoundHandler: notFoundHandler)
    }
}

/// The immutable, servable router — *is* the proposal's `HTTPServerRequestHandler`. Resolves the
/// request path through the frozen trie (binary-searched literal children) and dispatches the matched
/// method's handler, or answers `404`.
public struct FrozenTrieRouter<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: HTTPServerRequestHandler
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    let trie: FrozenRouteTrie
    let handlers: [TrieRouteBuilder<RequestContext, Reader, ResponseSender>.Handler]
    /// The fallback for unmatched requests; the built-in 404 below is used only when it's `nil` (an app
    /// that never called `registerNotFound`).
    let notFoundHandler: TrieRouteBuilder<RequestContext, Reader, ResponseSender>.Handler?

    public func handle(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender
    ) async throws {
        // Resolve without consuming, so the reader and sender are consumed exactly once — by the
        // matched handler, the fallback, or the built-in 404.
        guard let matched = trie.resolve(method: request.method, path: request.path ?? "/") else {
            if let notFoundHandler {
                try await notFoundHandler(request, requestContext, [:], reader, responseSender)
            } else {
                try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
            }
            return
        }
        try await handlers[matched.index](request, requestContext, matched.parameters, reader, responseSender)
    }
}
