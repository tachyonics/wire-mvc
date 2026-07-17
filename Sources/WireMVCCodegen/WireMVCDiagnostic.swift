public import SwiftDiagnostics
public import SwiftSyntax

/// The `@Controller` route-codegen diagnostics — node-anchored `error`s (M1 standard), each emitted at
/// the offending parameter or function so the fix-it location is precise. Shared by the `@Controller`
/// macro (which routes them to the expansion context) and the `WireMVCRouteGen` tool (which prints them
/// as `file:line:col: error:`).
public enum WireMVCDiagnostic: DiagnosticMessage, Sendable {
    case unannotatedParameter(String)
    case pathPlaceholderMissing(name: String, path: String)
    case missingResponseAnnotation(String)
    case jsonResponseOnVoid(String)
    case responseStatusOnValue(String)
    case unsupportedRawParameter(name: String, type: String)
    case rawRouteMissingSender(String)
    case middlewareFactoryRequiresFactory

    public var message: String {
        switch self {
        case .unannotatedParameter(let name):
            "handler parameter '\(name)' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header"
        case .pathPlaceholderMissing(let name, let path):
            "@Path '\(name)' has no matching '{\(name)}' placeholder in the route path \"\(path)\""
        case .missingResponseAnnotation(let route):
            "route '\(route)' needs exactly one response annotation — @JSONResponse (returns a body) or @ResponseStatus (Void)"
        case .jsonResponseOnVoid(let route):
            "@JSONResponse on '\(route)' requires a returned value; use @ResponseStatus for a Void handler"
        case .responseStatusOnValue(let route):
            "@ResponseStatus on '\(route)' requires a Void handler; use @JSONResponse to encode the returned value"
        case .unsupportedRawParameter(let name, let type):
            "@RawRoute parameter '\(name)' has unsupported type '\(type)' — a raw handler takes HTTPRequest, [String: Substring], the AsyncReader-constrained reader, and/or the HTTPResponseSender-constrained sender"
        case .rawRouteMissingSender(let route):
            "@RawRoute handler '\(route)' must take the response sender (a parameter generic over HTTPResponseSender) to write its response"
        case .middlewareFactoryRequiresFactory:
            "@MiddlewareFactory requires @Factory on the same type — it supplies the box-role mapping for a factory template. Add @Factory(key) to make this a Wire factory template."
        }
    }

    public var severity: DiagnosticSeverity { .error }

    public var diagnosticID: MessageID {
        let id: String
        switch self {
        case .unannotatedParameter: id = "unannotatedParameter"
        case .pathPlaceholderMissing: id = "pathPlaceholderMissing"
        case .missingResponseAnnotation: id = "missingResponseAnnotation"
        case .jsonResponseOnVoid: id = "jsonResponseOnVoid"
        case .responseStatusOnValue: id = "responseStatusOnValue"
        case .unsupportedRawParameter: id = "unsupportedRawParameter"
        case .rawRouteMissingSender: id = "rawRouteMissingSender"
        case .middlewareFactoryRequiresFactory: id = "middlewareFactoryRequiresFactory"
        }
        return MessageID(domain: "WireMVC", id: id)
    }
}

/// One route-codegen diagnostic captured against the syntax node it anchors to. The caller decides how
/// to surface it: the macro wraps it in a `SwiftDiagnostics.Diagnostic` for the expansion context; the
/// tool resolves the node's `SourceLocation` and prints a compiler-style line.
public struct RouteCodegenDiagnostic: Sendable {
    public let message: WireMVCDiagnostic
    public let node: Syntax

    public init(_ message: WireMVCDiagnostic, at node: some SyntaxProtocol) {
        self.message = message
        self.node = Syntax(node)
    }
}
