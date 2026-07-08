import SwiftSyntax
import SwiftSyntaxMacros

/// `@Controller(_ path: String)` / `@Controller()` — walks the controller's functions, and
/// for each one carrying a verb annotation (`@Get`/`@Post`/…) generates a `transport.register`
/// call inside a `TransportContributor` witness: bind each parameter (`@Path`/`@Query`/
/// `@JSONBody`/`@Header`), call the handler, encode the response (`@JSONResponse` /
/// `@ResponseStatus`). This is the member-walking, member-recognition adapter — the generated
/// body is exactly spike-11's hand-written shape.
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
            extension \(type.trimmed): TransportContributor {
                \(raw: access)func registerWireHandlers(on transport: any ServerTransport) throws {
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
        let (binds, callArgs) = try parameterBindings(of: function)
        let call = "try await self.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        let response = try responseLine(from: function.attributes, call: call, route: function.name.text)
        return """
            try transport.register(
            \(closureLiteral(binds: binds, response: response)),
                method: \(verb.method),
                path: "\(path)"
            )
            """
    }

    /// The `let <name> = try await <Binding><<Type>>.bind(...)` lines and the handler call
    /// argument list, one entry per handler parameter.
    private static func parameterBindings(
        of function: FunctionDeclSyntax
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
            let type = param.type.trimmedDescription
            let bindCall =
                "\(binding.wrapper)<\(type)>.bind(name: \"\(bindingName)\", request: request, body: requestBody, metadata: metadata)"
            binds.append("let \(internalName) = try await \(bindCall)")
            callArgs.append(isWildcard ? internalName : "\(param.firstName.text): \(internalName)")
        }
        return (binds, callArgs)
    }

    /// The response statement(s): a JSON body (`@JSONResponse`) or an empty status
    /// (`@ResponseStatus`). One response annotation is required.
    private static func responseLine(
        from attributes: AttributeListSyntax,
        call: String,
        route: String
    ) throws -> String {
        if let status = jsonResponseStatus(from: attributes) {
            return "return try WireMVCResponse.json(\(call), status: \(status))"
        }
        if let status = responseStatus(from: attributes) {
            return "\(call)\nreturn (HTTPResponse(status: \(status)), nil)"
        }
        throw WireMVCMacroError(
            "route '\(route)' needs a response annotation (@JSONResponse or @ResponseStatus)"
        )
    }

    /// The registration closure. With bindings, wraps them in a `do`/`catch` that maps a
    /// `WireMVCBindingError` to its response (415/422/400); without, just the response.
    private static func closureLiteral(binds: [String], response: String) -> String {
        guard !binds.isEmpty else {
            return "{ _, _, _ in\n\(response)\n}"
        }
        return """
            { request, requestBody, metadata in
                do {
            \(binds.joined(separator: "\n"))
            \(response)
                } catch let wireMVCBindingError as WireMVCBindingError {
                    return wireMVCBindingError.response
                }
            }
            """
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

    /// The `@JSONResponse` status expression (verbatim), `.ok` if present without a status,
    /// or `nil` if there's no `@JSONResponse`.
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
