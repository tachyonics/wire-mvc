// WireMVC's public surface and its generated `@Controller` witnesses are expressed in terms
// of `ServerTransport` / `HTTPResponse` / `HTTPBody`, so re-export those modules. A controller
// file then needs only `import WireMVC`: the macro-generated `registerWireHandlers(on:)`
// resolves `ServerTransport` and friends through here, without the author importing them.
@_exported import HTTPTypes
@_exported import OpenAPIRuntime
