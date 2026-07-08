import HTTPTypes
import OpenAPIRuntime

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Response encoding the generated witness calls. `@JSONResponse` routes go through `json`;
/// `@ResponseStatus` routes build the empty response inline in the witness.
public enum WireMVCResponse {
    /// `@JSONResponse[(status:)]` — encode an `Encodable` return as a JSON body.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status
    ) throws -> (HTTPResponse, HTTPBody?) {
        let data = try JSONEncoder().encode(value)
        return (HTTPResponse(status: status), HTTPBody(data))
    }
}
