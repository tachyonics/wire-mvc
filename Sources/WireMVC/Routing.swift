public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes

/// The registration surface `@Controller`'s generated witness targets. It keeps the server's
/// associated `RequestContext`/`Reader`/`ResponseSender` (they must match the server's, per
/// `HTTPServer.serve`'s `Handler.Reader == Reader`), so it is never boxed as `any`.
/// `WireMVC.router(for:server:)` builds one per serve.
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

/// Accumulates routes as a `RoutableHTTPServerBuilder`, then dispatches them as the single
/// `HTTPServerRequestHandler` the proposal's `serve` takes. Generic over the server's associated
/// types — the one place the `~Copyable` streaming machinery is threaded. Matches `{name}` path
/// templates, populating the handler's path parameters.
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
    private enum Segment: Sendable {
        case literal(String)
        case parameter(String)
    }

    private struct Route: Sendable {
        let method: HTTPRequest.Method
        let template: [Segment]
        let handler:
            @Sendable (
                HTTPRequest,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    }

    private var routes: [Route] = []

    public init() {}

    public mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    ) {
        routes.append(Route(method: method, template: Self.parse(path), handler: handler))
    }

    public func handle(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender
    ) async throws {
        // Resolve the route and its path parameters up front — no consuming — so the reader and
        // sender are consumed exactly once, on a single path (the matched handler, or the 404).
        let segments = Self.segments(Self.stripQuery(request.path ?? "/"))
        var matched: (route: Route, parameters: [String: Substring])?
        for route in routes where route.method == request.method {
            if let parameters = Self.match(template: route.template, segments: segments) {
                matched = (route, parameters)
                break
            }
        }
        guard let matched else {
            try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
            return
        }
        try await matched.route.handler(request, matched.parameters, reader, responseSender)
    }

    // MARK: - Path templates

    private static func parse(_ path: String) -> [Segment] {
        segments(path).map { segment in
            if segment.hasPrefix("{"), segment.hasSuffix("}") {
                return .parameter(String(segment.dropFirst().dropLast()))
            }
            return .literal(segment)
        }
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func stripQuery(_ path: String) -> String {
        if let index = path.firstIndex(of: "?") { return String(path[..<index]) }
        return path
    }

    private static func match(template: [Segment], segments: [String]) -> [String: Substring]? {
        guard template.count == segments.count else { return nil }
        var parameters: [String: Substring] = [:]
        for (templateSegment, pathSegment) in zip(template, segments) {
            switch templateSegment {
            case let .literal(literal):
                if literal != pathSegment { return nil }
            case let .parameter(name):
                parameters[name] = pathSegment[...]
            }
        }
        return parameters
    }
}
