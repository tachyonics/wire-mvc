import SwiftBasicFormat
import SwiftParser
public import SwiftSyntax

// The two output forms the shared route codegen feeds:
//   • the `@Controller` macro splices `renderRegisterWireRoutesWitness` into its peer *struct* (subject
//     accessor `controller`) — its structural scaffolding is unchanged;
//   • the `WireMVCRouteGen` tool wraps the same witness in an `extension` (subject accessor
//     `_wireSubject`) on the plugin-emitted structural proxy (Phase A), and formats it.
// Both fold the identical witness body from `RouteBlockGenerator`, so they cannot drift.

/// The `RouteContributor` witness signature — invariant boilerplate restating the `~Copyable`
/// requirements that don't propagate across the generic boundary. Shared so the macro's struct member
/// and the tool's extension member spell it identically.
private let witnessSignature = """
    registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    """

/// The full `RouteContributor` witness method — access + signature + `where` clause + `{ body }` — for
/// one controller, plus any route-shape diagnostics. `access` is the `"public "`/`"package "`/`""`
/// keyword prefix; `subjectAccessor` is the stored field the body calls the controller through;
/// `factoryKeys` are the `@Factory` template keys the middleware fold classifies against.
public func renderRegisterWireRoutesWitness(
    access: String,
    controller: ControllerDeclaration,
    pathPrefix: String,
    subjectAccessor: String,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping] = []
) -> (witness: String, diagnostics: [RouteCodegenDiagnostic]) {
    var generator = RouteBlockGenerator(
        subjectAccessor: subjectAccessor,
        factoryKeys: factoryKeys,
        globalErrorMappings: globalErrorMappings
    )
    let body = generator.routeBlocks(of: controller, pathPrefix: pathPrefix)
    let witness = """
        \(access)func \(witnessSignature)
        {
        \(body)
        }
        """
    return (witness, generator.diagnostics)
}

/// The route-contributor witness as an `extension` on the plugin-emitted structural proxy — the domain
/// half the `WireMVCRouteGen` tool emits into the consumer module (Phase A). The struct itself (fields +
/// init + `Sendable`) is emitted by WireGen; this extension adds the `RouteContributor` conformance and
/// the witness, meeting the struct on the `_wireSubject` / `_wireFactory_<key>` field names. Formatted so
/// the generated file reads cleanly.
public func renderRouteContributorExtension(
    controller: ControllerDeclaration,
    pathPrefix: String,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping] = []
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let rendered = renderRegisterWireRoutesWitness(
        access: controller.access,
        controller: controller,
        pathPrefix: pathPrefix,
        subjectAccessor: contributorProxySubjectAccessor,
        factoryKeys: factoryKeys,
        globalErrorMappings: globalErrorMappings
    )
    let raw = """
        extension \(controller.proxyTypeName): RouteContributor {
        \(rendered.witness)
        }
        """
    return (formatted(raw), rendered.diagnostics)
}

/// The stored-property name the plugin-emitted structural proxy holds its subject under — WireGen's
/// `_wireSubject` contract (`WireGenCore.contributorProxySubjectFieldName`). Restated here so the domain
/// witness references the same field the structural half declares. The two meet on this name.
public let contributorProxySubjectAccessor = "_wireSubject"

/// The method name the plugin-emitted structural proxy exposes a *bridging* (scoped) controller's
/// scope-entry thunk under — WireGen's `_wireEnterScope` contract
/// (`WireGenCore.contributorProxyScopeEntryFieldName`). A scoped controller's witness calls
/// `self._wireEnterScope(seed)` per request to construct the controller fresh; restated here so the
/// domain witness names the same field the structural half declares.
public let contributorProxyScopeEntryAccessor = "_wireEnterScope"

/// Parse each input Swift source, generate a route-contributor `extension` for every `@Controller` type
/// across them, and return one combined source (the files' imports + `import WireMVC` + the extensions)
/// plus the diagnostics resolved to source locations. No controllers → header only. This is the tool's
/// core; the executable is a thin CLI over it. Deterministic order: extensions by controller name,
/// imports sorted.
public func generateRouteContributors(
    files: [(path: String, source: String)]
) -> (source: String, diagnostics: [LocatedRouteDiagnostic]) {
    var extensions: [(name: String, source: String)] = []
    var located: [LocatedRouteDiagnostic] = []
    var imports: Set<String> = ["import WireMVC"]

    // Parse every source once, collecting its imports and its `@Factory` template keys — a controller in
    // one file may reference a factory declared in another, so the full key set must be known before any
    // witness is folded (it classifies each `@Middleware(key)` as factory-vs-graph-binding).
    let parsed = files.map { file -> (path: String, tree: SourceFileSyntax) in
        (file.path, Parser.parse(source: file.source))
    }
    var factoryKeys: Set<String> = []
    var bootstraps: [ControllerDeclaration] = []
    // The `@WireMVCBootstrap` composition root's `@ErrorResponse` is the global default error tier (M5.5
    // Phase 3), folded into every route below. Read once from the first bootstrap found, with its own
    // scope diagnostics (catch-all ordering, duplicate types) located to source.
    var globalErrorMappings: [ErrorMapping] = []
    var notFoundRegistration = ""  // the generated `builder.registerNotFound { … }` (M5.5 Phase 4)
    // The bootstrap's file converter, kept so the global-middleware proxy extension — rendered after the
    // first loop, when the full `factoryKeys` set is known — can locate its diagnostics (M5.5 Phase 5).
    var bootstrapConverter: SourceLocationConverter?
    var readBootstrap = false
    for file in parsed {
        imports.formUnion(importDeclarations(of: file.tree))
        factoryKeys.formUnion(factoryTemplateKeys(in: file.tree))
        let fileBootstraps = bootstrapDeclarations(in: file.tree)
        bootstraps.append(contentsOf: fileBootstraps)
        if !readBootstrap, let bootstrap = fileBootstraps.first {
            readBootstrap = true
            let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
            bootstrapConverter = converter
            func locate(_ diagnostics: [RouteCodegenDiagnostic]) {
                for diagnostic in diagnostics {
                    located.append(
                        LocatedRouteDiagnostic(
                            message: diagnostic.message,
                            location: diagnostic.node.startLocation(converter: converter)
                        )
                    )
                }
            }
            var reader = RouteBlockGenerator(subjectAccessor: "", factoryKeys: [], globalErrorMappings: [])
            globalErrorMappings = reader.errorMappings(from: bootstrap.attributes, scopeLabel: "bootstrap")
            locate(reader.diagnostics)
            let notFound = renderNotFoundRegistration(bootstrap: bootstrap)
            notFoundRegistration = notFound.registration
            locate(notFound.diagnostics)
        }
    }
    // The generated `@main` calls `Wire.bootstrap()`, so the consumer module needs `import Wire`
    // even when no controller source imported it directly.
    if !bootstraps.isEmpty { imports.insert("import Wire") }

    for file in parsed {
        let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        let finder = ControllerFinder()
        finder.walk(file.tree)
        for found in finder.controllers {
            let rendered = renderRouteContributorExtension(
                controller: found.declaration,
                pathPrefix: found.pathPrefix,
                factoryKeys: factoryKeys,
                globalErrorMappings: globalErrorMappings
            )
            extensions.append((found.declaration.name, rendered.source))
            for diagnostic in rendered.diagnostics {
                located.append(
                    LocatedRouteDiagnostic(
                        message: diagnostic.message,
                        location: diagnostic.node.startLocation(converter: converter)
                    )
                )
            }
        }
    }

    var lines = ["// Generated by WireMVCRouteGen — do not edit."]
    for line in imports.sorted() {
        lines.append("")
        lines.append(line)
    }
    for declaration in extensions.sorted(by: { $0.name < $1.name }) {
        lines.append("")
        lines.append(declaration.source)
    }
    // The `@WireMVCBootstrap` composition root's generated `@main` entry point. Exactly one is
    // expected; if a consumer declares more than one, the first gets the entry (a second `@main`
    // is a compile error the toolchain reports). Emitted last, at module scope.
    if let bootstrap = bootstraps.first {
        // The keyless global-middleware proxy's `wrapGlobalMiddleware` extension (M5.5 Phase 5) — rendered
        // here so it sees the full `factoryKeys` set (a global `@Middleware(key)` may reference a factory
        // declared in any file). The `@main` calls it on `graph._WireGlobalMiddleware_<Bootstrap>`.
        let proxyExtension = renderGlobalMiddlewareProxyExtension(bootstrap: bootstrap, factoryKeys: factoryKeys)
        if let converter = bootstrapConverter {
            for diagnostic in proxyExtension.diagnostics {
                located.append(
                    LocatedRouteDiagnostic(
                        message: diagnostic.message,
                        location: diagnostic.node.startLocation(converter: converter)
                    )
                )
            }
        }
        lines.append("")
        lines.append(proxyExtension.source)
        lines.append("")
        lines.append(renderBootstrapEntry(bootstrap: bootstrap, notFoundRegistration: notFoundRegistration))
    }
    lines.append("")
    return (lines.joined(separator: "\n"), located)
}

/// A route-codegen diagnostic resolved to a source location — what the tool prints as
/// `file:line:col: error:`.
public struct LocatedRouteDiagnostic: Sendable {
    public let message: WireMVCDiagnostic
    public let location: SourceLocation
}

/// Run a raw generated declaration through `BasicFormat` so the emitted file is consistently indented
/// — the role `assertMacroExpansion`/the compiler play for macro output, done explicitly here since the
/// tool writes plain text.
private func formatted(_ raw: String) -> String {
    Parser.parse(source: raw).formatted().description
}

/// Collect a parsed file's `import` declarations verbatim, so names the generated extensions reference
/// (the controller's domain types, WireMVC's routing surface) stay in scope.
private func importDeclarations(of sourceFile: SourceFileSyntax) -> [String] {
    sourceFile.statements.compactMap { statement in
        statement.item.as(ImportDeclSyntax.self)?.trimmedDescription
    }
}

/// The canonical key text of every `@Factory(key)` template declared in a parsed file — the set a
/// middleware fold classifies its `@Middleware(key)` arguments against (a match is a factory; anything
/// else is a graph binding). Walks the whole tree, since a factory template can be nested in an
/// enclosing type.
private func factoryTemplateKeys(in sourceFile: SourceFileSyntax) -> Set<String> {
    let finder = FactoryKeyFinder()
    finder.walk(sourceFile)
    return finder.keys
}

/// Walks a parsed file for every `@Factory(key)` attribute, capturing its key argument's canonical text.
private final class FactoryKeyFinder: SyntaxVisitor {
    private(set) var keys: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        guard node.attributeName.trimmedDescription == "Factory",
            case let .argumentList(list) = node.arguments,
            let first = list.first
        else { return .visitChildren }
        keys.insert(first.expression.trimmedDescription)
        return .visitChildren
    }
}

/// Walks a parsed file for every nominal type carrying `@Controller`, capturing its declaration and the
/// route path prefix the annotation supplies. A `SyntaxVisitor` so controllers nested in enclosing types
/// are found too.
private final class ControllerFinder: SyntaxVisitor {
    struct Found {
        let declaration: ControllerDeclaration
        let pathPrefix: String
    }
    private(set) var controllers: [Found] = []

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
        guard let controllerAttribute = controllerAttribute(in: declaration.attributes),
            let controller = ControllerDeclaration(declaration)
        else { return }
        controllers.append(Found(declaration: controller, pathPrefix: pathPrefix(of: controllerAttribute)))
    }

    private func controllerAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "Controller" {
            return attr
        }
        return nil
    }

    /// The `@Controller("/prefix")` path, or `""` for `@Controller` / `@Controller()`.
    private func pathPrefix(of attribute: AttributeSyntax) -> String {
        guard case let .argumentList(list) = attribute.arguments, let first = list.first else { return "" }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue ?? ""
    }
}
