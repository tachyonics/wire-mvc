import Foundation
import WireMVCCodegen

// `WireMVCRouteGen` — the WireMVC route-codegen tool (the domain half of Phase A). A thin CLI over
// `WireMVCCodegen.generateRouteContributors`: it parses the consumer's controller sources and emits a
// `_WireRoutes.swift` of `RouteContributor` extensions on the plugin-emitted structural proxies (the
// witness body referencing `_wireSubject` / `_wireFactory_<key>`). The build plugin runs it alongside
// WireGen (which emits the structs) — the two tools, one module, the field-name handshake. Until the A3
// cutover wires it into a build, it stands alone (spike-23 proved the two-tool orchestration).
//
// CLI: WireMVCRouteGen <output-path> <source-files...>
//
// On any route-shape diagnostic it prints compiler-style `file:line:col: error:` lines and exits
// non-zero, writing no output — the build plugin treats a missing output as a failed generation step.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: WireMVCRouteGen <output-path> <source-files...>\n".utf8))
    exit(1)
}
let outputPath = arguments[1]
let sourcePaths = Array(arguments.dropFirst(2))

var files: [(path: String, source: String)] = []
for path in sourcePaths {
    do {
        files.append((path, try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)))
    } catch {
        FileHandle.standardError.write(Data("error: failed to read \(path): \(error)\n".utf8))
        exit(1)
    }
}

let result = generateRouteContributors(files: files)

if !result.diagnostics.isEmpty {
    for diagnostic in result.diagnostics {
        let location = "\(diagnostic.location.file):\(diagnostic.location.line):\(diagnostic.location.column)"
        FileHandle.standardError.write(Data("\(location): error: \(diagnostic.message.message)\n".utf8))
    }
    exit(1)
}

do {
    try result.source.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("error: failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}
