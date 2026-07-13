import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Controller(_ path: String)` / `@Controller()` — walks the controller's functions, and for each
/// one carrying a verb annotation (`@Get`/`@Post`/…) generates a `builder.register` call inside a
/// `RouteContributor` witness: bind each parameter (`@Path`/`@Query`/`@JSONBody`/`@Header`), call the
/// handler, and send the response (`@JSONResponse` / `@ResponseStatus`). The witness is generic over
/// `some RoutableHTTPServerBuilder` and restates the inverse (`~Copyable`) requirements, because they
/// don't propagate across the generic boundary; the response is computed into a `WireMVCOutcome`
/// first, so the `consuming` sender is consumed exactly once.
public struct ControllerMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let prefix = firstStringLiteral(node.arguments) ?? ""
        let access = accessModifier(declaration.modifiers)

        var routeBlocks: [String] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard let verb = verb(from: function.attributes) else { continue }  // no verb → helper, skip
            // A route that fails validation is diagnosed at its offending node and skipped, so the
            // rest of the controller still generates (no cascade of downstream errors).
            if let block = routeBlock(function: function, verb: verb, prefix: prefix, in: context) {
                routeBlocks.append(block)
            }
        }

        let body = routeBlocks.joined(separator: "\n")
        let ext: DeclSyntax = """
            extension \(type.trimmed): RouteContributor {
                \(raw: access)func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                where
                    Builder.RequestContext: ~Copyable,
                    Builder.Reader: ~Copyable,
                    Builder.ResponseSender: ~Copyable,
                    Builder.ResponseSender.Writer: ~Copyable
                {
            \(raw: body)
                }
            }
            """
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: - Per-route codegen

    private static func routeBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        prefix: String,
        in context: some MacroExpansionContext
    ) -> String? {
        let path = joinPath(prefix, verb.path ?? "")
        if hasRawRoute(function) {
            return rawRouteBlock(function: function, verb: verb, path: path, in: context)
        }
        let hasBody = routeHasBody(function)
        guard let (binds, callArgs) = parameterBindings(of: function, path: path, hasBody: hasBody, in: context)
        else { return nil }
        let hasBinds = !binds.isEmpty
        let call = "try await self.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        guard let response = responseComputation(from: function, call: call, in: context) else { return nil }
        let requestName = hasBinds ? "request" : "_"
        let parametersName = hasBinds ? "pathParameters" : "_"
        let readerName = hasBody ? "reader" : "_"
        return """
            builder.register(method: \(verb.method), path: "\(path)") { \(requestName), \(parametersName), \(readerName), responseSender in
            \(closureBody(hasBinds: hasBinds, hasBody: hasBody, binds: binds, response: response))
            }
            """
    }

    // MARK: - Raw route codegen

    private static func hasRawRoute(_ function: FunctionDeclSyntax) -> Bool {
        for case let .attribute(attr) in function.attributes
        where attr.attributeName.trimmedDescription == "RawRoute" {
            return true
        }
        return false
    }

    private enum RawRole { case reader, sender }

    /// The `@RawRoute` register call: pass the register closure's primitives straight to the handler,
    /// matched by type (`HTTPRequest`, `[String: Substring]`) and by the reader/sender generic
    /// parameters' constraints (`AsyncReader`/`HTTPResponseSender`). No decode, no encode.
    private static func rawRouteBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        path: String,
        in context: some MacroExpansionContext
    ) -> String? {
        let roles = rawGenericRoles(function)
        var usesRequest = false
        var usesParameters = false
        var usesReader = false
        var usesSender = false
        var callArgs: [String] = []
        for param in function.signature.parameterClause.parameters {
            let type = strippingOwnership(param.type.trimmedDescription)
            let canonical = type.filter { !$0.isWhitespace }
            let registerArgument: String
            if canonical == "HTTPRequest" {
                registerArgument = "request"
                usesRequest = true
            } else if canonical == "[String:Substring]" {
                registerArgument = "pathParameters"
                usesParameters = true
            } else if roles[type] == .reader {
                registerArgument = "reader"
                usesReader = true
            } else if roles[type] == .sender {
                registerArgument = "responseSender"
                usesSender = true
            } else {
                let name = (param.secondName ?? param.firstName).text
                context.diagnose(
                    Diagnostic(node: param, message: WireMVCDiagnostic.unsupportedRawParameter(name: name, type: type))
                )
                return nil
            }
            let label = param.firstName.tokenKind == .wildcard ? "" : "\(param.firstName.text): "
            callArgs.append("\(label)\(registerArgument)")
        }
        guard usesSender else {
            context.diagnose(
                Diagnostic(node: function.name, message: WireMVCDiagnostic.rawRouteMissingSender(function.name.text))
            )
            return nil
        }
        let requestName = usesRequest ? "request" : "_"
        let parametersName = usesParameters ? "pathParameters" : "_"
        let readerName = usesReader ? "reader" : "_"
        return """
            builder.register(method: \(verb.method), path: "\(path)") { \(requestName), \(parametersName), \(readerName), responseSender in
                try await self.\(function.name.text)(\(callArgs.joined(separator: ", ")))
            }
            """
    }

    /// Strip leading ownership/transfer specifiers (`consuming sending Sender` → `Sender`) so the base
    /// type matches a generic-parameter name or a concrete raw-primitive type.
    private static func strippingOwnership(_ type: String) -> String {
        var base = type
        for specifier in ["consuming ", "borrowing ", "inout ", "sending ", "__owned ", "__shared "] {
            while base.hasPrefix(specifier) { base = String(base.dropFirst(specifier.count)) }
        }
        return base
    }

    /// Map each handler generic parameter to a raw role by its constraint — `AsyncReader` → reader,
    /// `HTTPResponseSender` → sender — so a parameter of that generic type binds to the matching
    /// register-closure primitive.
    private static func rawGenericRoles(_ function: FunctionDeclSyntax) -> [String: RawRole] {
        var roles: [String: RawRole] = [:]
        guard let generics = function.genericParameterClause else { return roles }
        for parameter in generics.parameters {
            let constraint = parameter.inheritedType?.trimmedDescription ?? ""
            if constraint.contains("AsyncReader") {
                roles[parameter.name.text] = .reader
            } else if constraint.contains("HTTPResponseSender") {
                roles[parameter.name.text] = .sender
            }
        }
        return roles
    }

    /// The `let <name> = try await <Binding><<Type>>.bind(...)` lines and the handler call argument
    /// list, one entry per handler parameter.
    private static func parameterBindings(
        of function: FunctionDeclSyntax,
        path: String,
        hasBody: Bool,
        in context: some MacroExpansionContext
    ) -> (binds: [String], callArgs: [String])? {
        var binds: [String] = []
        var callArgs: [String] = []
        for param in function.signature.parameterClause.parameters {
            let internalName = (param.secondName ?? param.firstName).text
            let isWildcard = param.firstName.tokenKind == .wildcard
            guard let binding = self.binding(from: param.attributes) else {
                context.diagnose(Diagnostic(node: param, message: WireMVCDiagnostic.unannotatedParameter(internalName)))
                return nil
            }
            let bindingName = binding.name ?? (isWildcard ? internalName : param.firstName.text)
            // `@Path name` must have a matching `{name}` in the route template — otherwise it can only
            // ever fail at runtime (`missingPathParameter`), so reject it at the seam.
            if binding.wrapper == "Path", !path.contains("{\(bindingName)}") {
                context.diagnose(
                    Diagnostic(
                        node: param,
                        message: WireMVCDiagnostic.pathPlaceholderMissing(name: bindingName, path: path)
                    )
                )
                return nil
            }
            binds.append(
                "let \(internalName) = \(bindExpression(for: param, binding: binding, name: bindingName, hasBody: hasBody))"
            )
            callArgs.append(isWildcard ? internalName : "\(param.firstName.text): \(internalName)")
        }
        return (binds, callArgs)
    }

    /// The binding call for one parameter: `bindOptional` (→ `T?`) for an optional type,
    /// `bindOptional(...) ?? default` for a defaulted parameter, else the throwing `bind`. `body` is
    /// the collected request body (`requestBody`) for routes with a `@JSONBody`, else `nil`.
    private static func bindExpression(
        for param: FunctionParameterSyntax,
        binding: Binding,
        name: String,
        hasBody: Bool
    ) -> String {
        let type = param.type.trimmedDescription
        let bodyArgument = hasBody ? "requestBody" : "nil"
        let args = "name: \"\(name)\", request: request, pathParameters: pathParameters, body: \(bodyArgument)"
        if type.hasSuffix("?") {
            let underlying = String(type.dropLast())
            return "try await \(binding.wrapper)<\(underlying)>.bindOptional(\(args))"
        }
        if let defaultValue = param.defaultValue?.value.trimmedDescription {
            return "try await \(binding.wrapper)<\(type)>.bindOptional(\(args)) ?? \(defaultValue)"
        }
        return "try await \(binding.wrapper)<\(type)>.bind(\(args))"
    }

    /// The statement that assigns `wireMVCOutcome`: a JSON body (`@JSONResponse`) or a bare status
    /// (`@ResponseStatus`, after calling the handler for its effect). One response annotation is
    /// required.
    private static func responseComputation(
        from function: FunctionDeclSyntax,
        call: String,
        in context: some MacroExpansionContext
    ) -> String? {
        let attributes = function.attributes
        let route = function.name.text
        let returnsValue = functionReturnsValue(function)
        if let status = jsonResponseStatus(from: attributes) {
            guard returnsValue else {
                context.diagnose(Diagnostic(node: function.name, message: WireMVCDiagnostic.jsonResponseOnVoid(route)))
                return nil
            }
            return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(status))"
        }
        if let status = responseStatus(from: attributes) {
            guard !returnsValue else {
                context.diagnose(
                    Diagnostic(node: function.name, message: WireMVCDiagnostic.responseStatusOnValue(route))
                )
                return nil
            }
            return "\(call)\nwireMVCOutcome = .status(\(status))"
        }
        context.diagnose(Diagnostic(node: function.name, message: WireMVCDiagnostic.missingResponseAnnotation(route)))
        return nil
    }

    /// Whether the handler returns a non-`Void` value — drives the `@JSONResponse`/`@ResponseStatus`
    /// vs. signature check. No return clause, or `Void`/`()`, is treated as Void.
    private static func functionReturnsValue(_ function: FunctionDeclSyntax) -> Bool {
        guard let returnType = function.signature.returnClause?.type else { return false }
        let text = returnType.trimmedDescription
        return text != "Void" && text != "()"
    }

    /// The registration closure body. Compute the outcome — collecting the body first when a
    /// `@JSONBody` is present, mapping a `WireMVCBindingError` to its status — then send it once.
    private static func closureBody(hasBinds: Bool, hasBody: Bool, binds: [String], response: String) -> String {
        guard hasBinds else {
            return """
                let wireMVCOutcome: WireMVCOutcome
                \(response)
                try await wireMVCOutcome.send(on: responseSender)
                """
        }
        let collect = hasBody ? "let requestBody = try await WireMVCRequest.collectBody(reader)\n" : ""
        return """
            let wireMVCOutcome: WireMVCOutcome
            do {
            \(collect)\(binds.joined(separator: "\n"))
            \(response)
            } catch let wireMVCBindingError as WireMVCBindingError {
                wireMVCOutcome = .status(wireMVCBindingError.status)
            }
            try await wireMVCOutcome.send(on: responseSender)
            """
    }

    private static func routeHasBody(_ function: FunctionDeclSyntax) -> Bool {
        for param in function.signature.parameterClause.parameters {
            if let binding = binding(from: param.attributes), binding.wrapper == "JSONBody" {
                return true
            }
        }
        return false
    }

    // MARK: - Attribute reading

    private struct Verb {
        let method: String  // e.g. ".get"
        let path: String?
    }

    private struct Binding {
        let wrapper: String  // e.g. "Path"
        let name: String?
    }

    private static func verbMethod(for name: String) -> String? {
        switch name {
        case "Get": return ".get"
        case "Post": return ".post"
        case "Put": return ".put"
        case "Patch": return ".patch"
        case "Delete": return ".delete"
        default: return nil
        }
    }

    private static func verb(from attributes: AttributeListSyntax) -> Verb? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if let method = verbMethod(for: name) {
                return Verb(method: method, path: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    private static let bindingWrappers: Set<String> = ["Path", "Query", "JSONBody", "Header"]

    private static func binding(from attributes: AttributeListSyntax) -> Binding? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if bindingWrappers.contains(name) {
                return Binding(wrapper: name, name: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    /// The `@JSONResponse` status expression (verbatim), `.ok` if present without a status, or `nil`
    /// if there's no `@JSONResponse`.
    private static func jsonResponseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "JSONResponse" {
            guard case let .argumentList(list) = attr.arguments else { return ".ok" }
            let statusArg = list.first { $0.label?.text == "status" }
            return statusArg?.expression.trimmedDescription ?? ".ok"
        }
        return nil
    }

    /// The `@ResponseStatus(_)` status expression (verbatim), or `nil` if absent.
    private static func responseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "ResponseStatus" {
            guard case let .argumentList(list) = attr.arguments, let first = list.first else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }

    // MARK: - Helpers

    private static func firstStringLiteral(_ arguments: AttributeSyntax.Arguments?) -> String? {
        guard case let .argumentList(list) = arguments, let first = list.first else { return nil }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    private static func accessModifier(_ modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }

    /// Join a controller prefix and a verb subpath into one `{name}`-template path.
    private static func joinPath(_ prefix: String, _ sub: String) -> String {
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let tail = sub.isEmpty ? "" : (sub.hasPrefix("/") ? sub : "/" + sub)
        let joined = head + tail
        return joined.isEmpty ? "/" : joined
    }
}

/// The `@Controller` codegen diagnostics — node-anchored `error`s (M1 standard), each emitted at the
/// offending parameter or function so the fix-it location is precise.
enum WireMVCDiagnostic: DiagnosticMessage {
    case unannotatedParameter(String)
    case pathPlaceholderMissing(name: String, path: String)
    case missingResponseAnnotation(String)
    case jsonResponseOnVoid(String)
    case responseStatusOnValue(String)
    case unsupportedRawParameter(name: String, type: String)
    case rawRouteMissingSender(String)

    var message: String {
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
        }
    }

    var severity: DiagnosticSeverity { .error }

    var diagnosticID: MessageID {
        let id: String
        switch self {
        case .unannotatedParameter: id = "unannotatedParameter"
        case .pathPlaceholderMissing: id = "pathPlaceholderMissing"
        case .missingResponseAnnotation: id = "missingResponseAnnotation"
        case .jsonResponseOnVoid: id = "jsonResponseOnVoid"
        case .responseStatusOnValue: id = "responseStatusOnValue"
        case .unsupportedRawParameter: id = "unsupportedRawParameter"
        case .rawRouteMissingSender: id = "rawRouteMissingSender"
        }
        return MessageID(domain: "WireMVC", id: id)
    }
}
