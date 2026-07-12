import BasicContainers
public import HTTPAPIs
public import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The response a route produces, computed *before* the response sender is touched — an already
/// encoded body with a status, or a bare status. The generated witness builds one of these (mapping
/// a binding failure to its status), then calls `send(on:)` exactly once, so the `consuming` sender
/// is consumed on a single path. `Sendable` (bytes + status) so it can be captured by a handler.
public enum WireMVCOutcome: Sendable {
    case body([UInt8], HTTPResponse.Status)
    case status(HTTPResponse.Status)

    /// Send this outcome on the response sender, consuming it.
    public func send<Sender: HTTPResponseSender & ~Copyable>(
        on sender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable {
        switch self {
        case let .body(bytes, status):
            var buffer = UniqueArray<UInt8>(copying: bytes)
            try await sender.sendAndFinish(HTTPResponse(status: status), buffer: &buffer)
        case let .status(status):
            try await sender.sendAndFinish(HTTPResponse(status: status))
        }
    }
}

/// Response encoding the generated witness calls. `@JSONResponse` routes go through `json`;
/// `@ResponseStatus` routes build `.status` inline in the witness.
public enum WireMVCResponse {
    /// `@JSONResponse[(status:)]` — encode an `Encodable` return as a JSON body.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status
    ) throws -> WireMVCOutcome {
        let data = try JSONEncoder().encode(value)
        return .body([UInt8](data), status)
    }
}
