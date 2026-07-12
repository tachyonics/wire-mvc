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
            routeBlocks.append(try routeBlock(function: function, verb: verb, prefix: prefix))
        }

        let body = routeBlocks.joined(separator: "\n")
        let ext: DeclSyntax = """
            extension \(type.trimmed): RouteContributor {
                \(raw: access)func registerWireHandlers<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
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
        prefix: String
    ) throws -> String {
        let path = joinPath(prefix, verb.path ?? "")
        let hasBody = routeHasBody(function)
        let (binds, callArgs) = try parameterBindings(of: function, hasBody: hasBody)
        let hasBinds = !binds.isEmpty
        let call = "try await self.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        let response = try responseComputation(from: function.attributes, call: call, route: function.name.text)
        let requestName = hasBinds ? "request" : "_"
        let parametersName = hasBinds ? "pathParameters" : "_"
        let readerName = hasBody ? "reader" : "_"
        return """
            builder.register(method: \(verb.method), path: "\(path)") { \(requestName), \(parametersName), \(readerName), responseSender in
            \(closureBody(hasBinds: hasBinds, hasBody: hasBody, binds: binds, response: response))
            }
            """
    }

    /// The `let <name> = try await <Binding><<Type>>.bind(...)` lines and the handler call argument
    /// list, one entry per handler parameter.
    private static func parameterBindings(
        of function: FunctionDeclSyntax,
        hasBody: Bool
    ) throws -> (binds: [String], callArgs: [String]) {
        var binds: [String] = []
        var callArgs: [String] = []
        for param in function.signature.parameterClause.parameters {
            let internalName = (param.secondName ?? param.firstName).text
            let isWildcard = param.firstName.tokenKind == .wildcard
            guard let binding = self.binding(from: param.attributes) else {
                throw WireMVCMacroError(
                    "handler parameter '\(internalName)' needs a binding annotation (@Path, @Query, @JSONBody, or @Header)"
                )
            }
            let bindingName = binding.name ?? (isWildcard ? internalName : param.firstName.text)
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
        from attributes: AttributeListSyntax,
        call: String,
        route: String
    ) throws -> String {
        if let status = jsonResponseStatus(from: attributes) {
            return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(status))"
        }
        if let status = responseStatus(from: attributes) {
            return "\(call)\nwireMVCOutcome = .status(\(status))"
        }
        throw WireMVCMacroError(
            "route '\(route)' needs a response annotation (@JSONResponse or @ResponseStatus)"
        )
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

struct WireMVCMacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
