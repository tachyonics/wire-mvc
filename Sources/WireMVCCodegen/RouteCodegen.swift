import SwiftSyntax

// The route-registration codegen — the domain half of a route contributor. Ported verbatim from the
// `@Controller` macro's per-route generation (verbs → `builder.register`, `@Path`/`@Query`/`@JSONBody`/
// `@Header` bindings, `@JSONResponse`/`@ResponseStatus`, `@RawRoute`, the `~Copyable` middleware fold),
// with two seams so one generator serves both callers:
//   • `subjectAccessor` — the stored field the witness calls the controller through. The macro's peer
//     struct names it `controller`; the plugin-emitted structural proxy names it `_wireSubject`. The
//     factory fields (`_wireFactory_<key>`) are named identically on both, so only this one differs.
//   • diagnostics are collected into an array rather than emitted to a macro expansion context, so the
//     `WireMVCRouteGen` tool can resolve their source locations and print compiler-style lines.
//
// This is the single source of truth: the macro and the tool both fold their witness body from
// `RouteBlockGenerator`, so the register/bind/encode logic can't drift between them. The generator's
// methods are split across extensions (per concern) to keep any one type body readable.

/// Generates the `builder.register` blocks that make up a route-contributor witness body, accumulating
/// any route-shape diagnostics. One instance per controller (holds the accumulated diagnostics).
struct RouteBlockGenerator {
    /// The field the witness calls the controller through — `controller` (macro peer struct) or
    /// `_wireSubject` (plugin-emitted structural proxy).
    let subjectAccessor: String
    /// The `@Factory` template keys visible across the input sources — how a non-`.self`
    /// `@Middleware(X)` argument is classified: a key in this set is a factory (its `create` is called
    /// on the lifted `_wireFactory_<key>`); any other key is a graph binding (referenced as `_wire<key>`).
    let factoryKeys: Set<String>
    private(set) var diagnostics: [RouteCodegenDiagnostic] = []

    /// The joined `builder.register` blocks for every verb-annotated function on the controller — the
    /// witness body. A route that fails validation is diagnosed at its offending node and skipped, so
    /// the rest of the controller still generates (no cascade of downstream errors).
    mutating func routeBlocks(of controller: ControllerDeclaration, pathPrefix: String) -> String {
        // Controller-scope `@Middleware` wraps every route, outer to each route's own middleware.
        let controllerMiddleware = middlewareConstructions(from: controller.attributes)
        var blocks: [String] = []
        for function in controller.functions {
            guard let verb = verb(from: function.attributes) else { continue }  // no verb → helper, skip
            if let block = routeBlock(
                function: function,
                verb: verb,
                prefix: pathPrefix,
                controllerMiddleware: controllerMiddleware
            ) {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n")
    }

    private mutating func routeBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        prefix: String,
        controllerMiddleware: [String]
    ) -> String? {
        let path = joinPath(prefix, verb.path ?? "")
        let middleware = controllerMiddleware + middlewareConstructions(from: function.attributes)
        if hasRawRoute(function) {
            return rawRouteBlock(function: function, verb: verb, path: path, middleware: middleware)
        }
        let hasBody = routeHasBody(function)
        guard let (binds, callArgs) = parameterBindings(of: function, path: path, hasBody: hasBody)
        else { return nil }
        let hasBinds = !binds.isEmpty
        let call = "try await self.\(subjectAccessor).\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        guard let response = responseComputation(from: function, call: call) else { return nil }
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
}

// MARK: - Raw route codegen

extension RouteBlockGenerator {
    private enum RawRole { case context, reader, sender }

    private func hasRawRoute(_ function: FunctionDeclSyntax) -> Bool {
        for case let .attribute(attr) in function.attributes
        where attr.attributeName.trimmedDescription == "RawRoute" {
            return true
        }
        return false
    }

    /// The `@RawRoute` register call: pass the register closure's primitives straight to the handler,
    /// matched by type (`HTTPRequest`, `[String: Substring]`) and by the reader/sender generic
    /// parameters' constraints (`AsyncReader`/`HTTPResponseSender`). No decode, no encode.
    fileprivate mutating func rawRouteBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        path: String,
        middleware: [String]
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
                diagnostics.append(
                    RouteCodegenDiagnostic(.unsupportedRawParameter(name: name, type: type), at: param)
                )
                return nil
            }
            let label = param.firstName.tokenKind == .wildcard ? "" : "\(param.firstName.text): "
            callArgs.append("\(label)\(registerArgument)")
        }
        guard usesSender else {
            diagnostics.append(
                RouteCodegenDiagnostic(.rawRouteMissingSender(function.name.text), at: function.name)
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
            terminalBody: "try await self.\(subjectAccessor).\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        )
    }

    /// Map each handler generic parameter to a raw role by its constraint — `AsyncReader` → reader,
    /// `HTTPResponseSender` → sender — so a parameter of that generic type binds to the matching
    /// register-closure primitive.
    private func rawGenericRoles(_ function: FunctionDeclSyntax) -> [String: RawRole] {
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

    /// Strip leading ownership/transfer specifiers (`consuming sending Sender` → `Sender`) so the base
    /// type matches a generic-parameter name or a concrete raw-primitive type.
    private func strippingOwnership(_ type: String) -> String {
        var base = type
        for specifier in ["consuming ", "borrowing ", "inout ", "sending ", "__owned ", "__shared "] {
            while base.hasPrefix(specifier) { base = String(base.dropFirst(specifier.count)) }
        }
        return base
    }
}

// MARK: - Register call & middleware fold

extension RouteBlockGenerator {
    /// The `builder.register` call, wrapping the terminal in the route's middleware fold when there is
    /// one. `requestName`/`contextName`/`parametersName`/`readerName` name (or `_`) the values the
    /// *terminal* uses. With no middleware they name the register closure's params directly. With
    /// middleware, the register closure binds request/context/reader/sender unconditionally to build the
    /// base box, and the terminal re-binds its values off the folded final box via `withContents` —
    /// path parameters are captured from the register closure (never boxed).
    fileprivate func emitRegister(
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
        // `middleware` holds each fold entry's expression — a graph binding read off the proxy
        // (`self._wire<Type>` / `self._wire<key>`) or a lifted factory's `create` call — computed by
        // `middlewareConstructions`.
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

    /// The fold-entry expression for each `@Middleware(...)`, in written order. Every middleware is read
    /// from the graph, off the proxy field the plugin lifts it onto — never constructed inline. The
    /// dispatch on the argument:
    /// - `T.self` → `self._wire<T>` — the middleware is a graph binding, injected by type. The plugin's
    ///   `.injectsFromGraph` pass gives the proxy a `_wire<T>` field holding that binding.
    /// - a key that names a `@Factory` template (`factoryKeys`) → `self._wireFactory_<key>.create(
    ///   Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)` — the
    ///   generic-with-deps factory case. The plugin synthesises `_WireFactory_<key>` and lifts it onto the
    ///   proxy; the fold calls its `create`, specialised at the builder's box associated types.
    /// - any other key → `self._wire<key>` — a keyed graph binding, injected by the same
    ///   `.injectsFromGraph` pass under the sanitised-key field name.
    func middlewareConstructions(from attributes: AttributeListSyntax) -> [String] {
        var constructions: [String] = []
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "Middleware" {
            guard
                let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                let first = arguments.first
            else { continue }
            let expression = first.expression.trimmedDescription
            if expression.hasSuffix(".self") {
                let type = String(expression.dropLast(".self".count))
                constructions.append("self.\(dependencyPropertyName(forType: type))")
            } else if factoryKeys.contains(expression) {
                let property = factoryPropertyName(forKey: expression)
                constructions.append(
                    "self.\(property).create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
                )
            } else {
                constructions.append("self.\(dependencyPropertyName(forKey: expression))")
            }
        }
        return constructions
    }
}

// MARK: - Parameter binding & response

extension RouteBlockGenerator {
    /// The `let <name> = try await <Binding><<Type>>.bind(...)` lines and the handler call argument
    /// list, one entry per handler parameter.
    fileprivate mutating func parameterBindings(
        of function: FunctionDeclSyntax,
        path: String,
        hasBody: Bool
    ) -> (binds: [String], callArgs: [String])? {
        var binds: [String] = []
        var callArgs: [String] = []
        for param in function.signature.parameterClause.parameters {
            let internalName = (param.secondName ?? param.firstName).text
            let isWildcard = param.firstName.tokenKind == .wildcard
            guard let binding = self.binding(from: param.attributes) else {
                diagnostics.append(RouteCodegenDiagnostic(.unannotatedParameter(internalName), at: param))
                return nil
            }
            let bindingName = binding.name ?? (isWildcard ? internalName : param.firstName.text)
            // `@Path name` must have a matching `{name}` in the route template — otherwise it can only
            // ever fail at runtime (`missingPathParameter`), so reject it at the seam.
            if binding.wrapper == "Path", !path.contains("{\(bindingName)}") {
                diagnostics.append(
                    RouteCodegenDiagnostic(.pathPlaceholderMissing(name: bindingName, path: path), at: param)
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
    private func bindExpression(
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
    fileprivate mutating func responseComputation(from function: FunctionDeclSyntax, call: String) -> String? {
        let attributes = function.attributes
        let route = function.name.text
        let returnsValue = functionReturnsValue(function)
        if let status = jsonResponseStatus(from: attributes) {
            guard returnsValue else {
                diagnostics.append(RouteCodegenDiagnostic(.jsonResponseOnVoid(route), at: function.name))
                return nil
            }
            return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(status))"
        }
        if let status = responseStatus(from: attributes) {
            guard !returnsValue else {
                diagnostics.append(RouteCodegenDiagnostic(.responseStatusOnValue(route), at: function.name))
                return nil
            }
            return "\(call)\nwireMVCOutcome = .status(\(status))"
        }
        diagnostics.append(RouteCodegenDiagnostic(.missingResponseAnnotation(route), at: function.name))
        return nil
    }

    /// Whether the handler returns a non-`Void` value — drives the `@JSONResponse`/`@ResponseStatus`
    /// vs. signature check. No return clause, or `Void`/`()`, is treated as Void.
    private func functionReturnsValue(_ function: FunctionDeclSyntax) -> Bool {
        guard let returnType = function.signature.returnClause?.type else { return false }
        let text = returnType.trimmedDescription
        return text != "Void" && text != "()"
    }

    /// The registration closure body. Compute the outcome — collecting the body first when a
    /// `@JSONBody` is present, mapping a `WireMVCBindingError` to its status — then send it once.
    fileprivate func closureBody(hasBinds: Bool, hasBody: Bool, binds: [String], response: String) -> String {
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

    fileprivate func routeHasBody(_ function: FunctionDeclSyntax) -> Bool {
        for param in function.signature.parameterClause.parameters {
            if let binding = binding(from: param.attributes), binding.wrapper == "JSONBody" {
                return true
            }
        }
        return false
    }
}

// MARK: - Attribute reading

extension RouteBlockGenerator {
    fileprivate struct Verb {
        let method: String  // e.g. ".get"
        let path: String?
    }

    private struct Binding {
        let wrapper: String  // e.g. "Path"
        let name: String?
    }

    private func verbMethod(for name: String) -> String? {
        switch name {
        case "Get": return ".get"
        case "Post": return ".post"
        case "Put": return ".put"
        case "Patch": return ".patch"
        case "Delete": return ".delete"
        default: return nil
        }
    }

    fileprivate func verb(from attributes: AttributeListSyntax) -> Verb? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if let method = verbMethod(for: name) {
                return Verb(method: method, path: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    private func binding(from attributes: AttributeListSyntax) -> Binding? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if routeBindingWrappers.contains(name) {
                return Binding(wrapper: name, name: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    /// The `@JSONResponse` status expression (verbatim), `.ok` if present without a status, or `nil`
    /// if there's no `@JSONResponse`.
    private func jsonResponseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "JSONResponse" {
            guard case let .argumentList(list) = attr.arguments else { return ".ok" }
            let statusArg = list.first { $0.label?.text == "status" }
            return statusArg?.expression.trimmedDescription ?? ".ok"
        }
        return nil
    }

    /// The `@ResponseStatus(_)` status expression (verbatim), or `nil` if absent.
    private func responseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "ResponseStatus" {
            guard case let .argumentList(list) = attr.arguments, let first = list.first else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }

    private func firstStringLiteral(_ arguments: AttributeSyntax.Arguments?) -> String? {
        guard case let .argumentList(list) = arguments, let first = list.first else { return nil }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    /// Join a controller prefix and a verb subpath into one `{name}`-template path.
    private func joinPath(_ prefix: String, _ sub: String) -> String {
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let tail = sub.isEmpty ? "" : (sub.hasPrefix("/") ? sub : "/" + sub)
        let joined = head + tail
        return joined.isEmpty ? "/" : joined
    }
}

/// The binding-wrapper attribute names a handler parameter can carry. File-scope (not a stored property)
/// so the generator's methods can live in extensions.
private let routeBindingWrappers: Set<String> = ["Path", "Query", "JSONBody", "Header"]

// MARK: - Factory-lift naming (structural ↔ domain handshake)

/// Derive the synthesised factory names from a `@Middleware(key)`'s canonical key text, using the same
/// sanitiser swift-wire's factory synthesis uses (any character outside `[A-Za-z0-9_]` → `_`). Both
/// sides must agree so the plugin's construction call resolves to the lifted property and the fold's
/// `create` names it.
public func sanitizedKeyFragment(_ key: String) -> String {
    String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
}
public func factoryPropertyName(forKey key: String) -> String { "_wireFactory_" + sanitizedKeyFragment(key) }
public func factoryTypeName(forKey key: String) -> String { "_WireFactory_" + sanitizedKeyFragment(key) }

/// The proxy field an `@Middleware(T.self)` binding is read through — the same name swift-wire's
/// adapter-dependency pass gives the by-type injected field: `_wire` + the simple (generics- and
/// namespace-stripped) type name, upper-cameled (`Mod.RequireAdmin<…>` → `_wireRequireAdmin`). Both
/// sides derive it identically so the witness and the plugin-emitted struct meet on the field.
public func dependencyPropertyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()
}

/// The proxy field an `@Middleware(key)` binding is read through when `key` is a graph binding key (not
/// a `@Factory` template) — `_wire` + the sanitised key, matching swift-wire's keyed adapter-dependency
/// field name.
public func dependencyPropertyName(forKey key: String) -> String { "_wire" + sanitizedKeyFragment(key) }
