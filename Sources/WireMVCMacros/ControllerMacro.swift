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
        // Controller-scope `@Middleware` wraps every route, outer to each route's own middleware.
        let controllerMiddleware = middlewareConstructions(from: declaration.attributes)

        var routeBlocks: [String] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard let verb = verb(from: function.attributes) else { continue }  // no verb → helper, skip
            // A route that fails validation is diagnosed at its offending node and skipped, so the
            // rest of the controller still generates (no cascade of downstream errors).
            if let block = routeBlock(
                function: function,
                verb: verb,
                prefix: prefix,
                controllerMiddleware: controllerMiddleware,
                in: context
            ) {
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
        controllerMiddleware: [String],
        in context: some MacroExpansionContext
    ) -> String? {
        let path = joinPath(prefix, verb.path ?? "")
        let middleware = controllerMiddleware + middlewareConstructions(from: function.attributes)
        if hasRawRoute(function) {
            return rawRouteBlock(function: function, verb: verb, path: path, middleware: middleware, in: context)
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
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            requestName: requestName,
            contextName: "_",
            parametersName: parametersName,
            readerName: readerName,
            terminalBody: closureBody(hasBinds: hasBinds, hasBody: hasBody, binds: binds, response: response)
        )
    }

    // MARK: - Raw route codegen

    private static func hasRawRoute(_ function: FunctionDeclSyntax) -> Bool {
        for case let .attribute(attr) in function.attributes
        where attr.attributeName.trimmedDescription == "RawRoute" {
            return true
        }
        return false
    }

    private enum RawRole { case context, reader, sender }

    /// The `@RawRoute` register call: pass the register closure's primitives straight to the handler,
    /// matched by type (`HTTPRequest`, `[String: Substring]`) and by the reader/sender generic
    /// parameters' constraints (`AsyncReader`/`HTTPResponseSender`). No decode, no encode.
    private static func rawRouteBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        path: String,
        middleware: [String],
        in context: some MacroExpansionContext
    ) -> String? {
        let roles = rawGenericRoles(function)
        var usesRequest = false
        var usesContext = false
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
            } else if roles[type] == .context {
                registerArgument = "requestContext"
                usesContext = true
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
        let contextName = usesContext ? "requestContext" : "_"
        let parametersName = usesParameters ? "pathParameters" : "_"
        let readerName = usesReader ? "reader" : "_"
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            requestName: requestName,
            contextName: contextName,
            parametersName: parametersName,
            readerName: readerName,
            terminalBody: "try await self.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        )
    }

    // MARK: - Middleware

    /// The `builder.register` call, wrapping the terminal in the route's middleware fold when there is
    /// one. `requestName`/`contextName`/`parametersName`/`readerName` name (or `_`) the values the
    /// *terminal* uses. With no middleware they name the register closure's params directly. With
    /// middleware, the register closure binds request/context/reader/sender unconditionally to build the
    /// base box, and the terminal re-binds its values off the folded final box via `withContents` —
    /// path parameters are captured from the register closure (never boxed).
    private static func emitRegister(
        verb: Verb,
        path: String,
        middleware: [String],
        requestName: String,
        contextName: String,
        parametersName: String,
        readerName: String,
        terminalBody: String
    ) -> String {
        guard !middleware.isEmpty else {
            return """
                builder.register(method: \(verb.method), path: "\(path)") { \(requestName), \(contextName), \(parametersName), \(readerName), responseSender in
                \(terminalBody)
                }
                """
        }
        // `middleware` holds each fold entry's complete construction expression (concrete `C()` or
        // generic `G<Builder.RequestContext, …>()`), computed by `middlewareConstructions`.
        let fold = middleware.joined(separator: "\n")
        return """
            builder.register(method: \(verb.method), path: "\(path)") { request, requestContext, \(parametersName), reader, responseSender in
                let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                let wireMVCChain = wireCompose {
            \(fold)
                }
                try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                    try await wireMVCFinalBox.withPendingContents { \(requestName), \(contextName), \(readerName), responseSender in
                    \(terminalBody)
                    }
                }
            }
            """
    }

    /// The fold-entry construction expression for each `@Middleware(...)`, in written order. The macro
    /// dispatches on the argument syntax:
    /// - `Concrete.self` (no generic args) → `Concrete()` — a concrete middleware (fits only downstream
    ///   of an erasing middleware, where the box is concrete; a misplacement is a compiler type error).
    /// - `Generic<…>.self` (generic args) → `Generic<Builder.RequestContext, Builder.Reader,
    ///   Builder.ResponseSender>()` — the written type args are WireMVC placeholders the macro discards,
    ///   re-spelling over the builder's associated types (inference doesn't flow through the fold).
    /// - a key reference (not `.self`) → `self._wireFactory_<key>.create(Builder.RequestContext.self,
    ///   Builder.Reader.self, Builder.ResponseSender.self)` — the generic-with-deps factory case. The
    ///   plugin synthesises `_WireFactory_<key>` and lifts it onto the controller (the member role adds
    ///   the property + wrapping init); the fold calls its `create`, specialised at the builder's box
    ///   associated types.
    private static func middlewareConstructions(from attributes: AttributeListSyntax) -> [String] {
        var constructions: [String] = []
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "Middleware" {
            guard
                let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                let first = arguments.first
            else { continue }
            let expression = first.expression.trimmedDescription
            guard expression.hasSuffix(".self") else {
                let property = factoryPropertyName(forKey: expression)
                constructions.append(
                    "self.\(property).create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
                )
                continue
            }
            let typeSpelling = String(expression.dropLast(".self".count))
            if let angle = typeSpelling.firstIndex(of: "<") {
                let name = typeSpelling[..<angle]
                constructions.append("\(name)<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()")
            } else {
                constructions.append("\(typeSpelling)()")
            }
        }
        return constructions
    }

    // MARK: - Factory-lift naming (macro ↔ plugin handshake)

    /// Derive the synthesised factory names from a `@Middleware(key)`'s canonical key text, using the
    /// same sanitiser swift-wire's synthesis uses (`sanitizedKeyFragment`: any character outside
    /// `[A-Za-z0-9_]` → `_`). Both sides must agree so the plugin's construction call resolves to the
    /// macro-generated wrapping init and the fold's `create` names the lifted property.
    private static func sanitizedKeyFragment(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }
    private static func factoryPropertyName(forKey key: String) -> String {
        "_wireFactory_" + sanitizedKeyFragment(key)
    }
    private static func factoryTypeName(forKey key: String) -> String {
        "_WireFactory_" + sanitizedKeyFragment(key)
    }
}

// MARK: - Member role: factory-lift ivars + wrapping init

extension ControllerMacro: MemberMacro {
    /// For each `@Middleware(key)` the controller consumes (controller- or route-scope), lift the
    /// plugin-synthesised factory onto the controller: add a `_wireFactory_<key>` property and one
    /// wrapping init that receives it. The property is an **IUO with a default** — `@Singleton`'s own
    /// generated init can't see it (member macros don't see each other's members), and the default is
    /// what lets that init still compile; the wrapping init populates it, and the plugin's construction
    /// call (the controller's `@Inject` deps followed by the appended factory deps) resolves to *this*
    /// init. Proven in spike-18.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        var keys: [String] = []
        func collect(_ attributes: AttributeListSyntax) {
            for case let .attribute(attr) in attributes
            where attr.attributeName.trimmedDescription == "Middleware" {
                guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                    let first = arguments.first
                else { continue }
                let expression = first.expression.trimmedDescription
                guard !expression.hasSuffix(".self") else { continue }  // concrete case — nothing to lift
                if !keys.contains(expression) { keys.append(expression) }  // dedupe, first-seen order
            }
        }
        collect(declaration.attributes)
        for member in declaration.memberBlock.members {
            if let function = member.decl.as(FunctionDeclSyntax.self) {
                collect(function.attributes)
            }
        }
        guard !keys.isEmpty else { return [] }

        let dependencies = injectInitDependencies(in: declaration)
        let access = accessModifier(declaration.modifiers)

        var members: [DeclSyntax] = []
        for key in keys {
            members.append(
                "var \(raw: factoryPropertyName(forKey: key)): \(raw: factoryTypeName(forKey: key))! = nil"
            )
        }

        let parameters =
            (dependencies.map { "\($0.name): \($0.type)" }
            + keys.map { "\(factoryPropertyName(forKey: $0)): \(factoryTypeName(forKey: $0))" })
            .joined(separator: ", ")
        let assignments =
            (dependencies.map { "    self.\($0.name) = \($0.name)" }
            + keys.map { "    self.\(factoryPropertyName(forKey: $0)) = \(factoryPropertyName(forKey: $0))" })
            .joined(separator: "\n")
        members.append(
            """
            \(raw: access)init(\(raw: parameters)) {
            \(raw: assignments)
            }
            """
        )
        return members
    }

    /// The controller's `@Inject` init-time dependencies in declaration order — the leading parameters
    /// of the wrapping init, matching what the plugin emits before the appended factory deps. Mirrors
    /// swift-wire's rule: non-`weak` `@Inject` stored properties are init parameters; `@Inject weak var`
    /// is post-construction and excluded. (A user-written `@Inject init` is not handled here — the 3.1
    /// controller shape is `@Inject` properties.)
    private static func injectInitDependencies(
        in declaration: some DeclGroupSyntax
    ) -> [(name: String, type: String)] {
        var dependencies: [(name: String, type: String)] = []
        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let hasInject = varDecl.attributes.contains { element in
                guard let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription else {
                    return false
                }
                return name == "Inject" || name == "Wire::Inject"
            }
            guard hasInject else { continue }
            let isStatic = varDecl.modifiers.contains { ["static", "class"].contains($0.name.text) }
            let isWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
            let isLet = varDecl.bindingSpecifier.tokenKind == .keyword(.let)
            guard !isStatic, !(isWeak && !isLet) else { continue }
            for binding in varDecl.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                dependencies.append((name: name, type: type))
            }
        }
        return dependencies
    }
}

extension ControllerMacro {

    // MARK: - Parameter binding & response

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
            } else if constraint.contains("RequestContext") {
                roles[parameter.name.text] = .context
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
}

extension ControllerMacro {

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
    case middlewareBindingKeyUnsupported

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
        case .middlewareBindingKeyUnsupported:
            "@Middleware currently takes a middleware type — 'SomeMiddleware.self' (concrete) or 'SomeMiddleware<WireContext, WireReader, WireSender>.self' (generic); referencing a graph binding by key is not yet supported"
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
        case .middlewareBindingKeyUnsupported: id = "middlewareBindingKeyUnsupported"
        }
        return MessageID(domain: "WireMVC", id: id)
    }
}
