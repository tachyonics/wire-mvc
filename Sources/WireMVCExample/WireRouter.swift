import AsyncStreaming
import HTTPAPIs
import HTTPTypes
import WireMVC

/// A concrete `RoutableHTTPServerBuilder` that is *also* the proposal's `HTTPServerRequestHandler`, so
/// it both collects routes (via `WireMVC.apply`) and serves them (via `server.serve(handler:)`).
/// WireMVC itself stays router-agnostic — it registers onto any builder; this lives in the example as
/// the concrete router that bridges the builder to a specific server's `serve`. Generic over the
/// server's associated types (the one place the `~Copyable` streaming machinery is threaded); matches
/// `{name}` path templates, populating the handler's path parameters.
struct WireRouter<
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
                consuming RequestContext,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    }

    private var routes: [Route] = []

    init() {}

    /// Infer the router's associated types from the server it will serve on, so callers needn't spell
    /// `WireRouter<Server.RequestContext, …>` by hand. The inverse (`~Copyable`) requirements are
    /// restated because they don't propagate across the generic boundary on their own.
    init<Server: HTTPServer>(for server: borrowing Server)
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

    mutating func register(
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
        routes.append(Route(method: method, template: Self.parse(path), handler: handler))
    }

    func handle(
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
        try await matched.route.handler(request, requestContext, matched.parameters, reader, responseSender)
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
