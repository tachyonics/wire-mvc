import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros
import WireMVCCodegen

/// `@Controller(_ path: String)` / `@Controller()` — generates the controller's **route-contributor
/// proxy**: a peer type holding the controller (built its ordinary way) plus every factory the
/// controller's `@Middleware(key)` use-sites demand, conforming to `RouteContributor` and carrying the
/// route witness. The controller itself stays a plain `@Singleton` — no wrapping init, no factory ivar,
/// no wrong way to build it. The witness calls the controller's handlers through `self.controller` and
/// folds each keyed middleware through `self._wireFactory_<key>.create(...)`. The name
/// (`_WireRouteContributor_<Controller>`) and the factory names are the structural↔domain handshake:
/// swift-wire's contributor-proxy synthesis constructs *this* type and lifts the demanded factories.
///
/// The route codegen (the witness body — verbs, `@Path`/`@Query`/… bindings, response modes,
/// `@RawRoute`, the `~Copyable` middleware fold) lives in `WireMVCCodegen`, shared verbatim with the
/// `WireMVCRouteGen` tool so the two cannot drift. This macro contributes only the *structural* half —
/// the peer struct's fields + init — and splices in the shared witness (subject accessor `controller`).
/// Phase A moves the structural half to WireGen and this macro becomes a marker (see the codegen notes);
/// until then it emits the whole proxy.
public struct ControllerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let controller = ControllerDeclaration(declaration) else { return [] }
        let prefix = firstStringLiteral(node.arguments) ?? ""
        let access = controller.access

        // The witness — the shared domain codegen. Its route-shape diagnostics are routed to the
        // expansion context (the tool routes the same diagnostics to stderr instead).
        let rendered = renderRegisterWireRoutesWitness(
            access: access,
            controller: controller,
            pathPrefix: prefix,
            subjectAccessor: "controller"
        )
        for diagnostic in rendered.diagnostics {
            context.diagnose(Diagnostic(node: diagnostic.node, message: diagnostic.message))
        }

        // The structural half — the peer struct's stored fields + init. The subject is the proxy's
        // first, unlabelled initialiser parameter (Wire's contributor-proxy synthesis passes it
        // positionally); each demanded factory follows, labelled.
        var storedFields = ["\(access)let controller: \(controller.selfType)"]
        var initParameters = ["_ controller: \(controller.selfType)"]
        var assignments = ["self.controller = controller"]
        for key in consumedFactoryKeys(controller) {
            let property = factoryPropertyName(forKey: key)
            let type = factoryTypeName(forKey: key)
            storedFields.append("\(access)let \(property): \(type)")
            initParameters.append("\(property): \(type)")
            assignments.append("self.\(property) = \(property)")
        }

        let proxy: DeclSyntax = """
            \(raw: access)struct \(raw: controller.proxyTypeName)\(raw: controller.genericClause): RouteContributor, Sendable\(raw: controller.whereClause) {
                \(raw: storedFields.joined(separator: "\n    "))
                \(raw: access)init(\(raw: initParameters.joined(separator: ", "))) {
                    \(raw: assignments.joined(separator: "\n        "))
                }
                \(raw: rendered.witness)
            }
            """
        return [proxy]
    }

    /// The `@Controller("prefix")` path literal, or `nil` for `@Controller` / `@Controller()`.
    private static func firstStringLiteral(_ arguments: AttributeSyntax.Arguments?) -> String? {
        guard case let .argumentList(list) = arguments, let first = list.first else { return nil }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }
}
