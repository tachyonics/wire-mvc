public import HTTPTypes

// The router's path-matching table — the routing algorithm, factored out of `WireRouter` so it is
// testable without the proposal server's `~Copyable` request/response machinery. Non-generic: it maps
// (method, path template) to a registration index; `WireRouter` holds the parallel handler array and
// looks it up by that index.
//
// v1 is a linear scan with first-registered-wins and `{name}` path parameters. Production hardening —
// radix/trie matching, 405-vs-404, static > param > wildcard precedence, trailing-slash policy,
// catch-all params, duplicate-route diagnostics — is tracked in [Notes/WireMVCRouter.md].

/// A parsed path template: a sequence of literal and parameter segments.
struct RouteTable: Sendable {
    enum Segment: Equatable, Sendable {
        case literal(String)
        case parameter(String)
    }

    private var templates: [(method: HTTPRequest.Method, segments: [Segment])] = []

    /// The number of registered templates — equals the next registration index.
    var count: Int { templates.count }

    /// Register `method` + `path`; returns its index (the caller stores the handler at the same index).
    mutating func add(method: HTTPRequest.Method, path: String) -> Int {
        templates.append((method, Self.parse(path)))
        return templates.count - 1
    }

    /// The index of the first registered route matching `method` + `path`, and the bound path
    /// parameters — or `nil` if nothing matches (the caller answers `404`).
    func resolve(method: HTTPRequest.Method, path: String) -> (index: Int, parameters: [String: Substring])? {
        let pathSegments = Self.segments(Self.stripQuery(path))
        for (index, template) in templates.enumerated() where template.method == method {
            if let parameters = Self.match(template: template.segments, segments: pathSegments) {
                return (index, parameters)
            }
        }
        return nil
    }

    // MARK: - Path templates

    static func parse(_ path: String) -> [Segment] {
        segments(path).map { segment in
            if segment.hasPrefix("{"), segment.hasSuffix("}") {
                return .parameter(String(segment.dropFirst().dropLast()))
            }
            return .literal(segment)
        }
    }

    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func stripQuery(_ path: String) -> String {
        if let index = path.firstIndex(of: "?") { return String(path[..<index]) }
        return path
    }

    static func match(template: [Segment], segments: [String]) -> [String: Substring]? {
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
