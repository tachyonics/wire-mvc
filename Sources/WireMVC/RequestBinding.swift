import HTTPTypes
import OpenAPIRuntime

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The extraction contract every parameter binding implements. `@Controller`'s generated
/// witness calls `bind` once per handler parameter to produce the value it passes to the
/// handler. Hosting the logic here (rather than inlining it in the macro) keeps the macro a
/// thin, binding-agnostic dispatcher and lets users add their own bindings: define a
/// `@propertyWrapper` conforming to `RequestBound` and `@Controller` uses it uniformly.
public protocol RequestBound {
    /// The value handed to the handler parameter.
    associatedtype Value

    /// Produce the bound value from the request. `name` is the binding name (the attribute
    /// argument if given, else the parameter name).
    static func bind(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> Value
}

extension RequestBound {
    /// Like `bind`, but returns `nil` when the value is simply absent (a missing path/query/
    /// header), while still throwing on a type mismatch. Backs optional (`T?`) and defaulted
    /// (`= expr`) handler parameters.
    public static func bindOptional(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> Value? {
        do {
            return try await bind(name: name, request: request, body: body, metadata: metadata)
        } catch let error as WireMVCBindingError where error.isAbsence {
            return nil
        }
    }
}

/// A binding failure the generated witness maps to a client-error response.
public enum WireMVCBindingError: Error {
    case missingPathParameter(String)
    case pathParameterTypeMismatch(String, String)
    case missingQueryParameter(String)
    case queryParameterTypeMismatch(String, String)
    case missingHeader(String)
    case headerTypeMismatch(String, String)
    case unsupportedMediaType
    case malformedBody

    /// The response the generated witness returns for this failure. `@JSONBody`'s
    /// content-type rules land here: 415 for a contradictory `Content-Type`, 422 for a
    /// malformed body; missing/mismatched path/query/header values are 400.
    public var response: (HTTPResponse, HTTPBody?) {
        switch self {
        case .unsupportedMediaType:
            return (HTTPResponse(status: .unsupportedMediaType), nil)  // 415
        case .malformedBody:
            return (HTTPResponse(status: .unprocessableContent), nil)  // 422
        case .missingPathParameter, .pathParameterTypeMismatch,
            .missingQueryParameter, .queryParameterTypeMismatch,
            .missingHeader, .headerTypeMismatch:
            return (HTTPResponse(status: .badRequest), nil)  // 400
        }
    }

    /// Whether this failure is a plain absence (vs a type mismatch or content-type error),
    /// so `bindOptional` can turn it into `nil` for optional/defaulted parameters.
    var isAbsence: Bool {
        switch self {
        case .missingPathParameter, .missingQueryParameter, .missingHeader: return true
        default: return false
        }
    }
}

// The binding wrappers are *unconstrained* structs so an optional parameter (`@Query x: T?`)
// is a valid backing `Wrapper<T?>`; the extraction (`RequestBound`/`bind`) lives on a
// constrained extension, and the macro calls it on the non-optional underlying type
// (`Wrapper<T>.bind` / `.bindOptional`), so `T: LosslessStringConvertible` is still enforced
// where it matters. A genuinely non-convertible required parameter is a compile error at the
// generated `bind` call.

/// `@Path name: T` — binds a `{name}` path template placeholder, converting via
/// `LosslessStringConvertible`.
@propertyWrapper
public struct Path<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Path: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> T {
        guard let raw = metadata.pathParameters[name] else {
            throw WireMVCBindingError.missingPathParameter(name)
        }
        guard let value = T(String(raw)) else {
            throw WireMVCBindingError.pathParameterTypeMismatch(name, String(raw))
        }
        return value
    }
}

/// `@Query name: T` — binds a query-string item, converting via `LosslessStringConvertible`.
@propertyWrapper
public struct Query<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Query: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> T {
        guard let query = request.path?.split(separator: "?", maxSplits: 1).dropFirst().first else {
            throw WireMVCBindingError.missingQueryParameter(name)
        }
        for pair in query.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard String(keyValue[0]) == name else { continue }
            let raw = keyValue.count > 1 ? (String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])) : ""
            guard let value = T(raw) else {
                throw WireMVCBindingError.queryParameterTypeMismatch(name, raw)
            }
            return value
        }
        throw WireMVCBindingError.missingQueryParameter(name)
    }
}

/// `@Header name: T` — binds an HTTP header value, converting via `LosslessStringConvertible`.
@propertyWrapper
public struct Header<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Header: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> T {
        guard let fieldName = HTTPField.Name(name), let raw = request.headerFields[fieldName] else {
            throw WireMVCBindingError.missingHeader(name)
        }
        guard let value = T(raw) else {
            throw WireMVCBindingError.headerTypeMismatch(name, raw)
        }
        return value
    }
}

/// `@JSONBody name: T` — decodes the JSON request body into `T`. Content-type rules: 415 on a
/// contradictory `Content-Type`, lenient on a missing one, 422 on malformed JSON.
@propertyWrapper
public struct JSONBody<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

extension JSONBody: RequestBound where T: Decodable {
    public static func bind(
        name: String,
        request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata
    ) async throws -> T {
        let contentType = request.headerFields[.contentType]
        if let contentType, !contentType.hasPrefix("application/json") {
            throw WireMVCBindingError.unsupportedMediaType  // 415
        }
        guard let body else { throw WireMVCBindingError.malformedBody }  // 422
        let data = try await Data(collecting: body, upTo: 1_000_000)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WireMVCBindingError.malformedBody  // 422
        }
    }
}
