import SwiftParser
public import SwiftSyntax

// The generated program entry point for a `@WireMVCBootstrap` composition root. `WireMVCRouteGen`
// emits a top-level `@main` type into the consumer module (in `_WireRoutes.swift`, alongside the
// route-contributor extensions) that: bootstraps the graph, reads the `@WireMVCBootstrap` binding
// off it, builds the server + route builder from the type's factories, registers the collated routes
// via `WireMVC.apply`, and serves the router alongside the graph's collated services.
//
// M5.5 Phase 1: no global middleware/error tiers, no introspection mount, no synthetic fallback route
// (later phases). The `@main` is *generated*, not user-written; the composition root carries only
// `@Singleton @WireMVCBootstrap` (the `@Singleton` makes it a graph binding, as `@Singleton @Controller`
// does), and the factory methods.

/// The generated entry type name — the `@main` struct emitted into `_WireRoutes.swift`.
let bootstrapEntryTypeName = "_WireMVCBootstrapEntry"

/// The graph property a `@Singleton`-bound `typeName` is reachable under on the generated `_WireGraph`
/// — WireGen names each binding `lowerCamel(sanitize(type))` (`WireGenCore` `identifierName(forType:key:)`).
/// For a simple, non-generic type name that is the first character lowercased; this restates that
/// contract so the generated `@main` reads `graph.<property>`. (Matches WireGen for plain identifiers;
/// generic/qualified bootstrap names are out of Phase-1 scope.)
func graphBindingPropertyName(_ typeName: String) -> String {
    guard let first = typeName.first else { return typeName }
    return first.lowercased() + typeName.dropFirst()
}

/// The `@main` entry source for the single `@WireMVCBootstrap` composition root. The serve loop is
/// inlined (concrete opaque locals, so the compiler infers the server/handler generics without any
/// explicit threading); only the service run is factored into the non-generic `WireMVC.runServices`.
/// `createServer` may throw (building a server configuration conventionally does), so the call is
/// prefixed with `try` when the declaration is `throws`.
func renderBootstrapEntry(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String
) -> String {
    let property = graphBindingPropertyName(bootstrap.name)
    let proxyProperty = graphBindingPropertyName(globalMiddlewareProxyTypeName(bootstrap.name))
    let createServerTry = functionThrows(named: "createServer", in: bootstrap) ? "try " : ""
    // The finalized router is wrapped once in the global-middleware front layer: the keyless proxy's
    // `wrapGlobalMiddleware` folds the Bootstrap's `@Middleware` factories around every request — matched
    // routes and the `@NotFound` fallback alike — or returns the router unchanged (identity) when there are
    // none. Always called, so the `@main` is uniform.
    let raw = """
        @main
        struct \(bootstrapEntryTypeName) {
            static func main() async throws {
                let graph = try await Wire.bootstrap()
                let bootstrap = graph.\(property)
                let server = \(createServerTry)bootstrap.createServer()
                var builder = bootstrap.createRouteBuilder(for: server)
                let services = try WireMVC.apply(graph, to: &builder)
                \(notFoundRegistration)
                let handler = builder.finalize()
                let wireMVCServed = graph.\(proxyProperty).wrapGlobalMiddleware(handler)
                try await WireMVC.serve(on: server, handler: wireMVCServed, services: services)
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The keyless global-middleware proxy type synthesised for a `@WireMVCBootstrap` root —
/// `_WireGlobalMiddleware_<name>`. The prefix is `wireMVCBootstrapAlias`'s `proxyTypePrefix`, so the
/// plugin-synthesised proxy binding and this tool's extension name the same type (mirrors
/// `ControllerDeclaration.proxyTypeName`'s relationship to `wireMVCControllerAlias`).
func globalMiddlewareProxyTypeName(_ bootstrapName: String) -> String {
    "_WireGlobalMiddleware_\(bootstrapName)"
}

/// The `extension _WireGlobalMiddleware_<Bootstrap>` carrying `wrapGlobalMiddleware<Handler>` — the front
/// layer's fold. Mirrors the controller proxy's `registerWireRoutes` witness: the plugin emits the proxy
/// struct (holding the reattributed `@Middleware` factories), this emits the method folding them around the
/// router via `GlobalMiddlewareHandler`. No global `@Middleware` → identity (`inner`), so the `@main` calls
/// it uniformly. Any by-type/keyed diagnostics ride out through `diagnostics`.
func renderGlobalMiddlewareProxyExtension(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let global = globalMiddlewareConstructions(bootstrap: bootstrap, factoryKeys: factoryKeys)
    let body: String
    if global.constructions.isEmpty {
        body = "inner"
    } else {
        let fold = global.constructions.joined(separator: "\n")
        body = """
            GlobalMiddlewareHandler(inner: inner, chain: wireCompose {
            \(fold)
            })
            """
    }
    let raw = """
        extension \(globalMiddlewareProxyTypeName(bootstrap.name)) {
            \(bootstrap.access)func wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)
            -> some HTTPServerRequestHandler<Handler.RequestContext, Handler.Reader, Handler.ResponseSender>
            where
                Handler.RequestContext: ~Copyable,
                Handler.Reader: ~Copyable,
                Handler.ResponseSender: ~Copyable,
                Handler.ResponseSender.Writer: ~Copyable
            {
                \(body)
            }
        }
        """
    return (Parser.parse(source: raw).formatted().description, global.diagnostics)
}

/// The fold-entry constructions for the Bootstrap's global `@Middleware`, read for the proxy's
/// `wrapGlobalMiddleware<Handler>` method. Only the **factory** form (`@Middleware(Key)`, generic over the
/// box) is valid at global scope — `self._wireFactory_<key>.create(Handler.RequestContext.self, …)` produces
/// a middleware over the router's box, composing in the non-transforming generic chain. A by-type
/// `@Middleware(T.self)` or a keyed graph binding is a concrete `Box<Fixed>` middleware that can't compose
/// there, so it is diagnosed (``WireMVCDiagnostic/globalMiddlewareUnsupportedArgument``).
func globalMiddlewareConstructions(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>
) -> (constructions: [String], diagnostics: [RouteCodegenDiagnostic]) {
    var constructions: [String] = []
    var diagnostics: [RouteCodegenDiagnostic] = []
    for case let .attribute(attr) in bootstrap.attributes
    where attr.attributeName.trimmedDescription == "Middleware" {
        guard
            let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first
        else { continue }
        let expression = first.expression.trimmedDescription
        if factoryKeys.contains(expression) {
            constructions.append(
                "self.\(factoryPropertyName(forKey: expression)).create(Handler.RequestContext.self, Handler.Reader.self, Handler.ResponseSender.self)"
            )
        } else {
            diagnostics.append(RouteCodegenDiagnostic(.globalMiddlewareUnsupportedArgument(expression), at: attr))
        }
    }
    return (constructions, diagnostics)
}

/// The `builder.registerNotFound { … }` for a `@WireMVCBootstrap`'s fallback (M5.5 Phase 4): the
/// `@NotFound` method rendered through the raw-route machinery (subject = the `@main`'s `bootstrap`
/// local), or a synthesised plain 404 when none is declared. The fallback is registered before
/// `finalize()`, so it's a real route the global tiers fold into. Any `@NotFound` diagnostics are
/// surfaced through `diagnostics`.
func renderNotFoundRegistration(
    bootstrap: ControllerDeclaration
) -> (registration: String, diagnostics: [RouteCodegenDiagnostic]) {
    let synth404 = """
        builder.registerNotFound { _, _, _, _, responseSender in
        try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
        }
        """
    guard let notFound = bootstrap.functions.first(where: hasNotFoundAttribute) else {
        return (synth404, [])
    }
    var generator = RouteBlockGenerator(subjectAccessor: "", factoryKeys: [], globalErrorMappings: [])
    guard let registration = generator.notFoundRegistration(function: notFound, subjectExpression: "bootstrap")
    else {
        return (synth404, generator.diagnostics)
    }
    return (registration, generator.diagnostics)
}

/// Whether a method carries `@NotFound`.
private func hasNotFoundAttribute(_ function: FunctionDeclSyntax) -> Bool {
    function.attributes.contains { attribute in
        if case let .attribute(attr) = attribute {
            return attr.attributeName.trimmedDescription == "NotFound"
        }
        return false
    }
}

/// Whether the named method on `declaration` is declared `throws` — so the generated entry mirrors the
/// factory's effect on its call.
private func functionThrows(named name: String, in declaration: ControllerDeclaration) -> Bool {
    for function in declaration.functions where function.name.text == name {
        return function.signature.effectSpecifiers?.throwsClause != nil
    }
    return false
}

/// Every nominal type carrying `@WireMVCBootstrap` in a parsed file, as a `ControllerDeclaration` (the
/// shared decl model — reused for its name/access/method access). A `SyntaxVisitor` so a bootstrap
/// nested in an enclosing type is found too.
func bootstrapDeclarations(in sourceFile: SourceFileSyntax) -> [ControllerDeclaration] {
    let finder = BootstrapFinder()
    finder.walk(sourceFile)
    return finder.declarations
}

private final class BootstrapFinder: SyntaxVisitor {
    private(set) var declarations: [ControllerDeclaration] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    private func record(_ declaration: some DeclSyntaxProtocol & DeclGroupSyntax) {
        let hasBootstrap = declaration.attributes.contains { attribute in
            if case let .attribute(attr) = attribute {
                return attr.attributeName.trimmedDescription == "WireMVCBootstrap"
            }
            return false
        }
        guard hasBootstrap, let bootstrap = ControllerDeclaration(declaration) else { return }
        declarations.append(bootstrap)
    }
}
