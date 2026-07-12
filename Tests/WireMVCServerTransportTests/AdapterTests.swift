#if ServerTransport
import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import OpenAPIRuntime
import Testing
import WireMVC
import WireMVCServerTransport

/// A minimal in-process `ServerTransport` — enough `{name}` matching to populate `pathParameters` and
/// drive the registered handlers. Stands in for a framework's transport (Hummingbird/Vapor).
final class MockTransport: ServerTransport, @unchecked Sendable {
    private struct Registration {
        let method: HTTPRequest.Method
        let template: [String]
        let handler:
            @concurrent @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            )
    }

    private var registrations: [Registration] = []

    func register(
        _ handler:
            @concurrent @Sendable @escaping (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            ),
        method: HTTPRequest.Method,
        path: String
    ) throws {
        registrations.append(.init(method: method, template: Self.segments(path), handler: handler))
    }

    func send(
        _ method: HTTPRequest.Method,
        _ path: String,
        body: HTTPBody? = nil
    ) async throws -> (
        HTTPResponse, [UInt8]
    ) {
        let requestSegments = Self.segments(path)
        for registration in registrations where registration.method == method {
            guard let params = Self.match(template: registration.template, path: requestSegments) else { continue }
            let request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
            let (response, responseBody) = try await registration.handler(request, body, .init(pathParameters: params))
            let bytes: [UInt8]
            if let responseBody {
                bytes = Array(try await HTTPBody.ByteChunk(collecting: responseBody, upTo: 1_000_000))
            } else {
                bytes = []
            }
            return (response, bytes)
        }
        return (HTTPResponse(status: .notFound), [])
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func match(template: [String], path: [String]) -> [String: Substring]? {
        guard template.count == path.count else { return nil }
        var params: [String: Substring] = [:]
        for (templateSegment, pathSegment) in zip(template, path) {
            if templateSegment.hasPrefix("{"), templateSegment.hasSuffix("}") {
                params[String(templateSegment.dropFirst().dropLast())] = pathSegment[...]
            } else if templateSegment != pathSegment {
                return nil
            }
        }
        return params
    }
}

/// A hand-written `RouteContributor` (what `@Controller` generates) — generic over the builder, its
/// closures driving the proposal reader/sender.
struct HelloController: RouteContributor {
    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: "/hello") { _, _, _, responseSender in
            var body = UniqueArray<UInt8>(copying: "Well, hello!".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
        builder.register(method: .post, path: "/echo") { _, _, reader, responseSender in
            var collected = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &collected, maximumSize: 1_000_000)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &collected)
        }
        builder.register(method: .get, path: "/users/{id}") { _, pathParameters, _, responseSender in
            let id = pathParameters["id"].map(String.init) ?? "?"
            var body = UniqueArray<UInt8>(copying: "user \(id)".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    }
}

/// Stands in for `Wire.bootstrap()`'s collated graph.
struct TestGraph: RouteComposable {
    var routeContributors: [any RouteContributor] { [HelloController()] }
}

@Suite("WireMVCServerTransport")
struct AdapterTests {
    /// `WireMVCServerTransport.apply` registers the collated (proposal-native) routes onto a
    /// `ServerTransport`; the bridge fabricates a reader from the request `HTTPBody` and a sender that
    /// collects the response, and the transport routes + supplies path parameters.
    @Test
    func servesProposalRoutesOnServerTransport() async throws {
        let transport = MockTransport()
        try WireMVCServerTransport.apply(TestGraph(), to: transport)

        let (hello, helloBody) = try await transport.send(.get, "/hello")
        #expect(hello.status == .ok && String(decoding: helloBody, as: UTF8.self) == "Well, hello!")

        let (echo, echoBody) = try await transport.send(.post, "/echo", body: HTTPBody("round-trip"))
        #expect(echo.status == .ok && String(decoding: echoBody, as: UTF8.self) == "round-trip")

        let (user, userBody) = try await transport.send(.get, "/users/42")
        #expect(user.status == .ok && String(decoding: userBody, as: UTF8.self) == "user 42")

        let (miss, _) = try await transport.send(.get, "/nope")
        #expect(miss.status == .notFound)
    }
}
#endif
