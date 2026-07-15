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
public struct ControllerMacro: PeerMacro {
    /// Generate the controller's **route-contributor proxy** — a peer type that holds the controller
    /// (built its ordinary way) plus every factory the controller's `@Middleware(key)` use-sites demand,
    /// conforms to `RouteContributor`, and carries the route witness. The controller itself stays a
    /// plain `@Singleton` — no wrapping init, no factory ivar, no wrong way to build it. The witness
    /// calls the controller's handlers through `self.controller` and folds each keyed middleware through
    /// `self._wireFactory_<key>.create(...)`. The name (`_WireRouteContributor_<Controller>`) and the
    /// factory names are the macro↔plugin handshake: swift-wire's contributor-proxy synthesis
    /// constructs *this* type and lifts the demanded factories onto it.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let controller = ControllerDeclaration(declaration) else { return [] }
        let prefix = firstStringLiteral(node.arguments) ?? ""
        let access = controller.access
        // Controller-scope `@Middleware` wraps every route, outer to each route's own middleware.
        let controllerMiddleware = middlewareConstructions(from: controller.attributes)

        var routeBlocks: [String] = []
        for function in controller.functions {
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

        let proxyName = "_WireRouteContributor_\(controller.name)"
        let controllerType = controller.selfType
        // The subject is the proxy's first, unlabelled initialiser parameter — Wire's contributor-proxy
        // synthesis passes it positionally (it names no member of this type). Factories follow, labelled.
        var storedFields = ["\(access)let controller: \(controllerType)"]
        var initParameters = ["_ controller: \(controllerType)"]
        var assignments = ["self.controller = controller"]
        for key in consumedFactoryKeys(controller) {
            let property = factoryPropertyName(forKey: key)
            let type = factoryTypeName(forKey: key)
            storedFields.append("\(access)let \(property): \(type)")
            initParameters.append("\(property): \(type)")
            assignments.append("self.\(property) = \(property)")
        }

        let proxy: DeclSyntax = """
            \(raw: access)struct \(raw: proxyName)\(raw: controller.genericClause): RouteContributor, Sendable\(raw: controller.whereClause) {
                \(raw: storedFields.joined(separator: "\n    "))
                \(raw: access)init(\(raw: initParameters.joined(separator: ", "))) {
                    \(raw: assignments.joined(separator: "\n        "))
                }
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
        return [proxy]
    }

    /// The factory keys the controller consumes across controller- and route-scope `@Middleware(key)`,
    /// deduped in first-seen order — the proxy stores one factory field per key. `.self` middleware are
    /// constructed inline in the witness (not lifted), so they contribute no field.
    private static func consumedFactoryKeys(_ controller: ControllerDeclaration) -> [String] {
        var keys: [String] = []
        func collect(_ attributes: AttributeListSyntax) {
            for case let .attribute(attr) in attributes
            where attr.attributeName.trimmedDescription == "Middleware" {
                guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                    let first = arguments.first
                else { continue }
                let expression = first.expression.trimmedDescription
                guard !expression.hasSuffix(".self") else { continue }  // concrete/generic case — inline
                if !keys.contains(expression) { keys.append(expression) }
            }
        }
        collect(controller.attributes)
        for function in controller.functions { collect(function.attributes) }
        return keys
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
        let call = "try await self.controller.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
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
            terminalBody: "try await self.controller.\(function.name.text)(\(callArgs.joined(separator: ", ")))"
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

// MARK: - Controller declaration reading

/// The pieces of the annotated controller the proxy needs — normalised across `struct` / `class` /
/// `actor` hosts, since a `PeerMacro` receives a bare `DeclSyntaxProtocol` rather than the type name and
/// generics an `ExtensionMacro` gets. `nil` for any declaration that isn't a nominal type.
private struct ControllerDeclaration {
    let name: String
    let genericParameterClause: GenericParameterClauseSyntax?
    let genericWhereClause: GenericWhereClauseSyntax?
    let attributes: AttributeListSyntax
    let modifiers: DeclModifierListSyntax
    let memberBlock: MemberBlockSyntax

    init?(_ declaration: some DeclSyntaxProtocol) {
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            name = structDecl.name.text
            genericParameterClause = structDecl.genericParameterClause
            genericWhereClause = structDecl.genericWhereClause
            attributes = structDecl.attributes
            modifiers = structDecl.modifiers
            memberBlock = structDecl.memberBlock
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            name = classDecl.name.text
            genericParameterClause = classDecl.genericParameterClause
            genericWhereClause = classDecl.genericWhereClause
            attributes = classDecl.attributes
            modifiers = classDecl.modifiers
            memberBlock = classDecl.memberBlock
        } else if let actorDecl = declaration.as(ActorDeclSyntax.self) {
            name = actorDecl.name.text
            genericParameterClause = actorDecl.genericParameterClause
            genericWhereClause = actorDecl.genericWhereClause
            attributes = actorDecl.attributes
            modifiers = actorDecl.modifiers
            memberBlock = actorDecl.memberBlock
        } else {
            return nil
        }
    }

    var functions: [FunctionDeclSyntax] {
        memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
    }

    /// `"public "` / `"package "` / `""` — the proxy inherits the controller's visibility so the graph
    /// consumer (another module) can construct it.
    var access: String {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }

    /// The generic parameter clause verbatim (`"<Repository: TodoRepository>"`) restated on the proxy,
    /// or `""` for a non-generic controller.
    var genericClause: String { genericParameterClause?.trimmedDescription ?? "" }

    /// The generic `where` clause verbatim, space-prefixed for splicing after `Sendable`, or `""`.
    var whereClause: String { genericWhereClause.map { " \($0.trimmedDescription)" } ?? "" }

    /// The controller type the proxy stores — its name applied to its own parameter names
    /// (`TodosController<Repository>`, so the proxy threads the graph's lift parameter transitively), or
    /// the bare name for a non-generic controller.
    var selfType: String {
        guard let parameters = genericParameterClause?.parameters, !parameters.isEmpty else { return name }
        let arguments = parameters.map { $0.name.text }.joined(separator: ", ")
        return "\(name)<\(arguments)>"
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
