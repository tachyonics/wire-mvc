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
func renderBootstrapEntry(bootstrap: ControllerDeclaration) -> String {
    let property = graphBindingPropertyName(bootstrap.name)
    let createServerTry = functionThrows(named: "createServer", in: bootstrap) ? "try " : ""
    let raw = """
        @main
        struct \(bootstrapEntryTypeName) {
            static func main() async throws {
                let graph = try await Wire.bootstrap()
                let bootstrap = graph.\(property)
                let server = \(createServerTry)bootstrap.createServer()
                var builder = bootstrap.createRoutableBuilder(for: server)
                let services = try WireMVC.apply(graph, to: &builder)
                try await WireMVC.serve(on: server, handler: builder, services: services)
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
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
