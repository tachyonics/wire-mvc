// WireMVC's public surface and its generated `@Controller` witnesses are expressed in terms of the
// proposal's server types (`HTTPServer`, the response sender) and `HTTPRequest`/`HTTPResponse`, so
// re-export those modules. A controller file then needs only `import WireMVC`: the macro-generated
// `registerWireHandlers(on:)` resolves these through here, without the author importing them.
@_exported public import HTTPAPIs
@_exported public import HTTPTypes
