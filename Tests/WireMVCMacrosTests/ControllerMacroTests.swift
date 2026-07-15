import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WireMVCMacros
import XCTest

private let macros: [String: any Macro.Type] = [
    "Controller": ControllerMacro.self,
    "Get": RouteMarkerMacro.self,
    "Post": RouteMarkerMacro.self,
    "Put": RouteMarkerMacro.self,
    "Patch": RouteMarkerMacro.self,
    "Delete": RouteMarkerMacro.self,
    "JSONResponse": RouteMarkerMacro.self,
    "ResponseStatus": RouteMarkerMacro.self,
    "RawRoute": RouteMarkerMacro.self,
    "Middleware": RouteMarkerMacro.self,
]

final class ControllerMacroTests: XCTestCase {
    /// The generated `RouteContributor` witness: one `builder.register` with decode → call → encode.
    func testGeneratesRegisterWitness() {
        assertMacroExpansion(
            """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """,
            expandedSource: """
                struct Todos {
                    func get(@Path id: String) async throws -> Todo {
                        fatalError()
                    }
                }

                extension Todos: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/todos/{id}") { request, _, pathParameters, _, responseSender in
                            let wireMVCOutcome: WireMVCOutcome
                            do {
                                let id = try await Path<String>.bind(name: "id", request: request, pathParameters: pathParameters, body: nil)
                                wireMVCOutcome = try WireMVCResponse.json(try await self.get(id: id), status: .ok)
                            } catch let wireMVCBindingError as WireMVCBindingError {
                                wireMVCOutcome = .status(wireMVCBindingError.status)
                            }
                            try await wireMVCOutcome.send(on: responseSender)
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    func testUnannotatedParameterDiagnoses() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                @JSONResponse
                func f(id: String) -> Int {
                    0
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f(id: String) -> Int {
                        0
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header",
                    line: 5,
                    column: 12
                )
            ],
            macros: macros
        )
    }

    func testPathPlaceholderMismatchDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct C {
                @Get
                @JSONResponse
                func f(@Path id: String) -> Int {
                    0
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f(@Path id: String) -> Int {
                        0
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Path 'id' has no matching '{id}' placeholder in the route path \"/users\"",
                    line: 5,
                    column: 12
                )
            ],
            macros: macros
        )
    }

    func testMissingResponseAnnotationDiagnoses() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                func f() -> Int {
                    0
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() -> Int {
                        0
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "route 'f' needs exactly one response annotation — @JSONResponse (returns a body) or @ResponseStatus (Void)",
                    line: 4,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testJSONResponseOnVoidDiagnoses() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                @JSONResponse
                func f() {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@JSONResponse on 'f' requires a returned value; use @ResponseStatus for a Void handler",
                    line: 5,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testResponseStatusOnValueDiagnoses() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                @ResponseStatus(.ok)
                func f() -> Int {
                    0
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() -> Int {
                        0
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@ResponseStatus on 'f' requires a Void handler; use @JSONResponse to encode the returned value",
                    line: 5,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    /// `@RawRoute` passes the register-closure primitives straight to a generic handler — here the
    /// sender only, matched by its `HTTPResponseSender` constraint; the reader/request are `_`.
    func testRawRouteGeneratesPassthrough() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct C {
                @Get("/events")
                @RawRoute
                func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                        responseSender: consuming sending Sender
                    ) async throws where Sender.Writer: ~Copyable {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/users/events") { _, _, _, _, responseSender in
                            try await self.events(responseSender: responseSender)
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    /// A `@RawRoute` handler can also claim the server's per-request `RequestContext`: a generic
    /// parameter constrained to `HTTPServerCapability.RequestContext` matches the context slot, so the
    /// generated closure binds `requestContext` and forwards it (alongside the sender).
    func testRawRouteBindsContext() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct C {
                @Get("/whoami")
                @RawRoute
                func whoami<
                    Context: HTTPServerCapability.RequestContext & ~Copyable,
                    Sender: HTTPResponseSender & ~Copyable & SendableMetatype
                >(
                    context: consuming Context,
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func whoami<
                        Context: HTTPServerCapability.RequestContext & ~Copyable,
                        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
                    >(
                        context: consuming Context,
                        responseSender: consuming sending Sender
                    ) async throws where Sender.Writer: ~Copyable {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/users/whoami") { _, requestContext, _, _, responseSender in
                            try await self.whoami(context: requestContext, responseSender: responseSender)
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    func testRawRouteMissingSenderDiagnoses() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                @RawRoute
                func f(_ request: HTTPRequest) async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f(_ request: HTTPRequest) async throws {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {

                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@RawRoute handler 'f' must take the response sender (a parameter generic over HTTPResponseSender) to write its response",
                    line: 5,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    // MARK: - Middleware

    /// A generic middleware (case 2) is named with placeholder type args the macro discards, re-spelling
    /// the middleware over the builder's associated types and folding it around the terminal.
    func testGenericMiddlewareFold() {
        assertMacroExpansion(
            """
            @Controller("/x")
            @Middleware(LogMiddleware<WireContext, WireReader, WireSender>.self)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() async throws {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/x/y") { request, requestContext, _, reader, responseSender in
                            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                            let wireMVCChain = wireCompose {
                                LogMiddleware<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()
                            }
                            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                                let wireMVCOutcome: WireMVCOutcome
                                try await self.f()
                                wireMVCOutcome = .status(.noContent)
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    /// Controller-scope and route-scope `@Middleware` compose on one route, controller-outer to
    /// route-inner (the order they appear in the `wireCompose` fold).
    func testControllerAndRouteMiddlewareOrder() {
        assertMacroExpansion(
            """
            @Controller("/x")
            @Middleware(ControllerMiddleware<WireContext, WireReader, WireSender>.self)
            struct C {
                @Middleware(RouteMiddleware<WireContext, WireReader, WireSender>.self)
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() async throws {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/x/y") { request, requestContext, _, reader, responseSender in
                            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                            let wireMVCChain = wireCompose {
                                ControllerMiddleware<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()
                                RouteMiddleware<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()
                            }
                            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                                let wireMVCOutcome: WireMVCOutcome
                                try await self.f()
                                wireMVCOutcome = .status(.noContent)
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    /// A concrete middleware (case 1) on the route (not the controller) is constructed directly.
    func testConcreteMiddlewareFold() {
        assertMacroExpansion(
            """
            @Controller("/x")
            struct C {
                @Middleware(ConcreteMiddleware.self)
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() async throws {
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/x/y") { request, requestContext, _, reader, responseSender in
                            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                            let wireMVCChain = wireCompose {
                                ConcreteMiddleware()
                            }
                            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                                let wireMVCOutcome: WireMVCOutcome
                                try await self.f()
                                wireMVCOutcome = .status(.noContent)
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """,
            macros: macros
        )
    }

    /// A `@Middleware(key)` (a `FactoryKey`, not `.self`) lifts the plugin-synthesised factory onto the
    /// controller: the member role adds a `_wireFactory_<key>` IUO property + a wrapping init, and the
    /// fold calls its `create` at the builder's box types.
    func testMiddlewareFactoryKeyLifts() {
        assertMacroExpansion(
            """
            @Controller("/x")
            @Middleware(Keys.session)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() async throws {
                    }

                    var _wireFactory_Keys_session: _WireFactory_Keys_session! = nil

                    init(_wireFactory_Keys_session: _WireFactory_Keys_session) {
                        self._wireFactory_Keys_session = _wireFactory_Keys_session
                    }
                }

                extension C: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/x/y") { request, requestContext, _, reader, responseSender in
                            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                            let wireMVCChain = wireCompose {
                                self._wireFactory_Keys_session.create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)
                            }
                            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                                let wireMVCOutcome: WireMVCOutcome
                                try await self.f()
                                wireMVCOutcome = .status(.noContent)
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """,
            macros: macros
        )
    }
}
