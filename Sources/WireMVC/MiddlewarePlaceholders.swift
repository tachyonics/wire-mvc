public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import BasicContainers

// Placeholder server types, used *only* to name a generic middleware in `@Middleware`. A generic type
// can't be named `Generic.self` (no metatype without type arguments), so a generic middleware is written
// `@Middleware(Generic<WireContext, WireReader, WireSender>.self)`; the `@Controller` macro discards
// these arguments and re-spells the middleware over the builder's real associated types. They are never
// instantiated or run — they exist solely so the annotation's metatype type-checks.

/// Placeholder for a server's `RequestContext`, for naming a generic middleware in `@Middleware`.
public struct WireContext: HTTPServerCapability.RequestContext {}

/// Placeholder for a server's request-body `Reader`, for naming a generic middleware in `@Middleware`.
public struct WireReader: AsyncReader {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = Never
    public typealias FinalElement = HTTPFields?
    public typealias Buffer = UniqueArray<UInt8>

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        do {
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// Placeholder writer for `WireSender`.
public struct WireWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Never
    public typealias FinalElement = HTTPFields?

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {}

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {}
}

/// Placeholder for a server's `ResponseSender`, for naming a generic middleware in `@Middleware`.
public struct WireSender: HTTPResponseSender {
    public typealias Writer = WireWriter
    public mutating func sendInformational(_ response: HTTPResponse) async throws {}
    public consuming func send(_ response: HTTPResponse) async throws -> WireWriter { WireWriter() }
}
