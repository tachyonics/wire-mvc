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
    registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    """

/// The full `RouteContributor` witness method — access + signature + `where` clause + `{ body }` — for
/// one controller, plus any route-shape diagnostics. `access` is the `"public "`/`"package "`/`""`
/// keyword prefix; `subjectAccessor` is the stored field the body calls the controller through.
public func renderRegisterWireRoutesWitness(
    access: String,
    controller: ControllerDeclaration,
    pathPrefix: String,
    subjectAccessor: String
) -> (witness: String, diagnostics: [RouteCodegenDiagnostic]) {
    var generator = RouteBlockGenerator(subjectAccessor: subjectAccessor)
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
    pathPrefix: String
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let rendered = renderRegisterWireRoutesWitness(
        access: controller.access,
        controller: controller,
        pathPrefix: pathPrefix,
        subjectAccessor: contributorProxySubjectAccessor
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

    for file in files {
        let sourceFile = Parser.parse(source: file.source)
        let converter = SourceLocationConverter(fileName: file.path, tree: sourceFile)
        imports.formUnion(importDeclarations(of: sourceFile))

        let finder = ControllerFinder()
        finder.walk(sourceFile)
        for found in finder.controllers {
            let rendered = renderRouteContributorExtension(
                controller: found.declaration,
                pathPrefix: found.pathPrefix
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
