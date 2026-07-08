import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireMVCMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ControllerMacro.self, RouteMarkerMacro.self]
}
