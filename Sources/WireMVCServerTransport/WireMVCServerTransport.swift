#if ServerTransport
public import OpenAPIRuntime
public import ServiceLifecycle
public import Wire
public import WireMVC

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Serve proposal-native WireMVC controllers on OpenAPIRuntime's `ServerTransport` (Hummingbird/Vapor
// via swift-openapi-hummingbird/-vapor). The bridge adapts the proposal's `~Copyable` streaming
// reader/sender that `@Controller`'s witnesses drive down to the transport's copyable `HTTPBody`
// currency. It's a thin per-route adapter: `ServerTransport` does its own routing and supplies the
// path parameters, so there's no router here — one `transport.register` per collated route.
//
// The bridge types are ordinary *copyable* structs: `AsyncReader`/`HTTPResponseSender`/
// `CallerAsyncWriter` are `~Copyable`/`~Escapable`, but that relaxes the constraint (conformers may be
// non-copyable), it doesn't require it.

/// Empty request context — the proposal's `HTTPServerCapability.RequestContext` is a marker; there is
/// no real server context on the ServerTransport path.
private struct BridgeRequestContext: HTTPServerCapability.RequestContext {}

/// A copyable in-memory `AsyncReader` over the request body bytes — delivers them in one read.
private struct BridgeReader: AsyncReader {
    typealias ReadElement = UInt8
    typealias ReadFailure = Never
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    private let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>(copying: bytes)
        do {
            // `.some(nil)` — terminal chunk (end of stream) with no trailers.
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// Where the response sender deposits what it's sent — read back after the handler returns, since the
/// sender is consumed and can't be inspected directly.
private final class ResponseSink: @unchecked Sendable {
    var response: HTTPResponse?
    var body: [UInt8] = []
}

/// A copyable in-memory `CallerAsyncWriter` that appends written bytes into a `ResponseSink`.
private struct BridgeWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let sink: ResponseSink

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        drain(&buffer)
    }

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        drain(&buffer)
    }

    private func drain<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ buffer: inout Buffer
    ) where Buffer.Element: ~Copyable {
        var consumer = buffer.consumeAll()
        while let byte = consumer.next() { sink.body.append(byte) }
    }
}

/// A copyable in-memory `HTTPResponseSender` that records the response head + body into a `ResponseSink`.
private struct BridgeResponseSender: HTTPResponseSender {
    typealias Writer = BridgeWriter

    let sink: ResponseSink

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> BridgeWriter {
        sink.response = response
        return BridgeWriter(sink: sink)
    }
}

/// The bridge builder: a `RoutableHTTPServerBuilder` whose reader/sender are the copyable in-memory
/// types. It accumulates routes, then `apply(to:)` forwards each onto a `ServerTransport`.
private struct ServerTransportRouteBuilder: RoutableHTTPServerBuilder {
    typealias RequestContext = BridgeRequestContext
    typealias Reader = BridgeReader
    typealias ResponseSender = BridgeResponseSender

    typealias Handler =
        @Sendable (
            HTTPRequest,
            [String: Substring],
            consuming sending BridgeReader,
            consuming sending BridgeResponseSender
        ) async throws -> Void

    private struct Route {
        let method: HTTPRequest.Method
        let path: String
        let handler: Handler
    }

    private var routes: [Route] = []

    mutating func register(method: HTTPRequest.Method, path: String, handler: @escaping Handler) {
        routes.append(Route(method: method, path: path, handler: handler))
    }

    /// Forward each collected route onto a `ServerTransport`: the framework routes + provides path
    /// parameters; per request we fabricate a reader from the `HTTPBody?` and a sender that collects
    /// into `(HTTPResponse, HTTPBody?)`.
    consuming func apply(to transport: some ServerTransport) throws {
        for route in routes {
            try transport.register(
                { request, requestBody, metadata in
                    let bytes: [UInt8]
                    if let requestBody {
                        bytes = Array(try await HTTPBody.ByteChunk(collecting: requestBody, upTo: 1_000_000))
                    } else {
                        bytes = []
                    }
                    let sink = ResponseSink()
                    try await route.handler(
                        request,
                        metadata.pathParameters,
                        BridgeReader(bytes),
                        BridgeResponseSender(sink: sink)
                    )
                    let responseBody = sink.body.isEmpty ? nil : HTTPBody(Data(sink.body))
                    return (sink.response ?? HTTPResponse(status: .internalServerError), responseBody)
                },
                method: route.method,
                path: route.path
            )
        }
    }
}

/// Serves proposal-native WireMVC controllers on a `ServerTransport`. The `ServerTransport`-era
/// counterpart to `WireMVC.apply(_:to:)` (which targets a `RoutableHTTPServerBuilder` directly): a
/// Hummingbird/Vapor runtime uses this to serve the *same* controllers a proposal server does.
public enum WireMVCServerTransport {
    /// Register the graph's collated controllers onto a `ServerTransport` and return the graph's
    /// collated app-scoped `ServiceLifecycle` services to hand to `Application(services:)` / a
    /// `ServiceGroup`.
    @discardableResult
    public static func apply(
        _ graph: some WireMVCComposable,
        to transport: some ServerTransport
    ) throws -> [any Service] {
        var builder = ServerTransportRouteBuilder()
        let services = try WireMVC.apply(graph, to: &builder)
        try builder.apply(to: transport)
        return services
    }

    /// Register a `GET` endpoint serving the graph's wiring model (`introspect()`) as JSON onto a
    /// `ServerTransport`.
    public static func mountIntrospection(
        for graph: some Introspectable,
        on transport: some ServerTransport,
        at path: String = "/wiring"
    ) throws {
        var builder = ServerTransportRouteBuilder()
        try WireMVC.mountIntrospection(for: graph, into: &builder, at: path)
        try builder.apply(to: transport)
    }
}
#endif
