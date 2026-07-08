import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A minimal in-process `ServerTransport` standing in for a real router. It stores the
/// registrations the generated witness makes and matches `{name}` path templates to populate
/// `ServerRequestMetadata` — enough to drive the generated handlers end-to-end. Live serving
/// on Hummingbird/Vapor is the M5.1 cross-runtime gate.
final class DispatchingTransport: ServerTransport, @unchecked Sendable {
    private struct Registration {
        let method: HTTPRequest.Method
        let template: [String]
        let handler: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    }

    private var registrations: [Registration] = []

    func register(
        _ handler:
            @Sendable @escaping (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
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
        contentType: String? = nil,
        body: HTTPBody? = nil
    ) async throws -> (HTTPResponse, String) {
        let requestSegments = Self.segments(Self.stripQuery(path))
        for registration in registrations where registration.method == method {
            guard let params = Self.match(template: registration.template, path: requestSegments) else {
                continue
            }
            var fields = HTTPFields()
            if let contentType { fields[.contentType] = contentType }
            let request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path, headerFields: fields)
            let (response, responseBody) = try await registration.handler(request, body, .init(pathParameters: params))
            let text: String
            if let responseBody {
                let data = try await Data(collecting: responseBody, upTo: 1_000_000)
                text = String(bytes: data, encoding: .utf8) ?? ""
            } else {
                text = ""
            }
            return (response, text)
        }
        return (HTTPResponse(status: .notFound), "")
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func stripQuery(_ path: String) -> String {
        if let index = path.firstIndex(of: "?") { return String(path[..<index]) }
        return path
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
