import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// The domain half of a route contributor: the `WireMVCRouteGen` tool (via `WireMVCCodegen`) emits the
/// `RouteContributor` witness as an `extension` on the plugin-emitted structural proxy, folding the route
/// codegen (verbs, `@Path`/… bindings, response modes, `@RawRoute`, the `~Copyable` middleware fold) off
/// the proxy's `_wireSubject` / `_wire<…>` / `_wireFactory_<key>` fields. These tests pin the emitted
/// extension for every route shape, the `@Middleware` classification (factory / by-type / by-key), and the
/// diagnostics.
@Suite("Route-contributor generation")
struct RouteContributorGenerationTests {

    /// Parse a fixture and return its first `@Controller` type as a `ControllerDeclaration`.
    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let declaration = statement.item.asProtocol(DeclGroupSyntax.self) as? (any DeclSyntaxProtocol),
                let controller = ControllerDeclaration(declaration)
            {
                return controller
            }
        }
        fatalError("fixture has no controller")
    }

    private func witnessBody(
        _ source: String,
        pathPrefix: String,
        subjectAccessor: String,
        factoryKeys: Set<String> = []
    ) -> String {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: pathPrefix,
            subjectAccessor: subjectAccessor,
            factoryKeys: factoryKeys
        ).witness
    }

    // MARK: - Golden extensions, per route shape

    @Test func plainJSONRouteWithPathBinding() {
        let source = """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/todos",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Todos: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
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
                                wireMVCOutcome = try WireMVCResponse.json(try await self._wireSubject.get(id: id), status: .ok)
                            } catch let wireMVCBindingError as WireMVCBindingError {
                                wireMVCOutcome = .status(wireMVCBindingError.status)
                            }
                            try await wireMVCOutcome.send(on: responseSender)
                        }
                    }
                }
                """
        )
    }

    // MARK: - @WireMVCBootstrap composition root (M5.5 Phase 1)

    /// The generated `@main` entry: reads the `@WireMVCBootstrap` binding off the graph
    /// (`graph.appBootstrap`), builds the server + router from its factories, applies the collated
    /// routes, and serves via `WireMVC.serve`. `createServer` is `throws`, so its call carries `try`.
    @Test func bootstrapEntryGeneratesMain() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                @Inject let config: ServerConfig
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        #expect(
            renderBootstrapEntry(bootstrap: controller(source)) == """
                @main
                struct _WireMVCBootstrapEntry {
                    static func main() async throws {
                        let graph = try await Wire.bootstrap()
                        let bootstrap = graph.appBootstrap
                        let server = try bootstrap.createServer()
                        var builder = bootstrap.createRouteBuilder(for: server)
                        let services = try WireMVC.apply(graph, to: &builder)
                        let handler = builder.finalize()
                        try await WireMVC.serve(on: server, handler: handler, services: services)
                    }
                }
                """
        )
    }

    /// A non-`throws` `createServer` drops the `try` on its call — the entry mirrors the factory's effect.
    @Test func bootstrapEntryOmitsTryForNonThrowingCreateServer() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() -> NIOHTTPServer { fatalError() }
            }
            """
        #expect(renderBootstrapEntry(bootstrap: controller(source)).contains("let server = bootstrap.createServer()"))
    }

    /// End to end: `generateRouteContributors` finds `@WireMVCBootstrap`, emits the `@main` entry, and
    /// adds `import Wire` (the entry calls `Wire.bootstrap()`).
    @Test func generateEmitsBootstrapEntryAndWireImport() {
        let source = """
            import WireMVC
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = generateRouteContributors(files: [("App.swift", source)])
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("struct _WireMVCBootstrapEntry {"))
        #expect(rendered.source.contains("let bootstrap = graph.appBootstrap"))
        #expect(rendered.source.contains("import Wire\n"))
    }

    @Test func scopedControllerConstructsPerRequestViaScopeEntry() {
        // A `@Scoped(seed:)` controller is a bridge proxy: its witness constructs the controller fresh
        // per request from the proxy's `_wireEnterScope` thunk (seeded by the request), then dispatches
        // on that local — never the held `_wireSubject` (a bridge proxy has none).
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/sessions")
            struct Sessions {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Session {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/sessions",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "let (wireMVCController, wireMVCScopeTeardown) = try await self._wireEnterScope(request)"
            )
        )
        // The scope's teardown runs on every exit via an async defer (M5.4.5); BasicFormat may reflow the block.
        #expect(rendered.source.contains("defer {"))
        #expect(rendered.source.contains("_ = await wireMVCScopeTeardown()"))
        #expect(rendered.source.contains("try await wireMVCController.get(id: id)"))
        #expect(!rendered.source.contains("_wireSubject"))
    }

    @Test func middlewareFactoryKeyFold() {
        let source = """
            @Controller("/x")
            @Middleware(Keys.session)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: ["Keys.session"]
        )
        #expect(
            rendered.source == """
                extension _WireRouteContributor_C: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
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
                                try await self._wireSubject.f()
                                wireMVCOutcome = .status(.noContent)
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """
        )
    }

    /// Every parameter-binding branch on one route — `@Path`/`@Query`/`@Header`/`@JSONBody`, an optional
    /// (`bindOptional`), a defaulted (`bindOptional(...) ?? default`), body collection, and a custom
    /// response status.
    @Test func allParameterBindingShapes() {
        let source = """
            @Controller("/search")
            struct Search {
                @Post("/{scope}")
                @JSONResponse(status: .created)
                func run(
                    @Path scope: String,
                    @Query("q") query: String,
                    @Query limit: Int?,
                    @Header("X-Trace") trace: String = "none",
                    @JSONBody filter: Filter
                ) async throws -> Results {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/search",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Search: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .post, path: "/search/{scope}") { request, _, pathParameters, reader, responseSender in
                            let wireMVCOutcome: WireMVCOutcome
                            do {
                                let requestBody = try await WireMVCRequest.collectBody(reader)
                                let scope = try await Path<String>.bind(name: "scope", request: request, pathParameters: pathParameters, body: requestBody)
                                let query = try await Query<String>.bind(name: "q", request: request, pathParameters: pathParameters, body: requestBody)
                                let limit = try await Query<Int>.bindOptional(name: "limit", request: request, pathParameters: pathParameters, body: requestBody)
                                let trace = try await Header<String>.bindOptional(name: "X-Trace", request: request, pathParameters: pathParameters, body: requestBody) ?? "none"
                                let filter = try await JSONBody<Filter>.bind(name: "filter", request: request, pathParameters: pathParameters, body: requestBody)
                                wireMVCOutcome = try WireMVCResponse.json(try await self._wireSubject.run(scope: scope, query: query, limit: limit, trace: trace, filter: filter), status: .created)
                            } catch let wireMVCBindingError as WireMVCBindingError {
                                wireMVCOutcome = .status(wireMVCBindingError.status)
                            }
                            try await wireMVCOutcome.send(on: responseSender)
                        }
                    }
                }
                """
        )
    }

    // MARK: - @ErrorResponse (route error handling)

    /// A controller-scope `(E.self, .status)` shorthand covers every route: the terminal `catch`
    /// consults it (folding the binding-error built-in and re-throwing an unmapped error to the framework).
    @Test func controllerScopeStatusShorthandCoversRoute() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        // No catch-all → guarded assignment that re-throws when nothing matched.
        #expect(rendered.source.contains("} catch let wireMVCError {"))
        #expect(rendered.source.contains("(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)"))
        // The binding-error built-in is folded in (BasicFormat may reflow the trailing closure).
        #expect(rendered.source.contains("(wireMVCError as? WireMVCBindingError).map"))
        #expect(rendered.source.contains("WireMVCOutcome.status($0.status)"))
        #expect(rendered.source.contains("throw wireMVCError"))
        // The shipped binding-only catch is gone once @ErrorResponse is present.
        #expect(!rendered.source.contains("catch let wireMVCBindingError as WireMVCBindingError"))
    }

    /// A route-scope entry is consulted before the controller entry (route overrides): a route closure
    /// mapping is folded ahead of the controller's status shorthand.
    @Test func routeClosureOverridesController() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get("/{id}")
                @JSONResponse
                @ErrorResponse({ (e: NotFound) in .status(.gone) })
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        let generated = rendered.source
        // Route closure is folded (through the helper), consulted before the controller's status shorthand.
        let routeCall = generated.range(of: "wireMVCRespond(to: wireMVCError, ({ (e: NotFound) in")
        let controllerStatus = generated.range(
            of: "(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)"
        )
        #expect(routeCall != nil && controllerStatus != nil)
        #expect(routeCall!.lowerBound < controllerStatus!.lowerBound)
        // A closure mapping throws through the helper, so the chain is `try`-prefixed.
        #expect(generated.contains("= try"))
    }

    /// An inline typed-parameter closure is spliced and applied through `wireMVCRespond`.
    @Test func inlineClosureMapping() {
        let source = """
            @Controller("/users")
            struct Users {
                @Post
                @JSONResponse(status: .created)
                @ErrorResponse({ (e: ValidationError) in try .json(Problem(e.message), status: .unprocessableContent) })
                func create(@JSONBody new: NewUser) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("wireMVCRespond(to: wireMVCError, ({ (e: ValidationError) in"))
    }

    /// A `Swift.Error` catch-all closure folds through `wireMVCRespondAny` as the non-optional terminal,
    /// so the assignment is direct (no guarded `else { throw }`).
    @Test func catchAllClosureIsTerminal() {
        let source = """
            @Controller("/users")
            @ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
            struct Users {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("wireMVCRespondAny(to: wireMVCError, ({ (e: Swift.Error) in"))
        #expect(rendered.source.contains("wireMVCOutcome = try ("))
        // A catch-all matches everything, so nothing is re-thrown from the terminal.
        #expect(!rendered.source.contains("throw wireMVCError"))
    }

    /// A route with no bindings still gets a `do`/`catch` when it declares an `@ErrorResponse`, so a
    /// handler throw is mapped (the shipped no-binds fast path has no `catch`).
    @Test func noBindsRouteGainsCatchForErrorResponse() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get
                @JSONResponse
                @ErrorResponse(NotFound.self, .notFound)
                func list() async throws -> [User] {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("do {"))
        #expect(rendered.source.contains("} catch let wireMVCError {"))
        // No bindings → the binding-error built-in is not folded in.
        #expect(!rendered.source.contains("as? WireMVCBindingError"))
    }

    /// A `@Scoped(seed:)` controller with an `@ErrorResponse` moves the scope-entry construction *inside*
    /// the `do`, so a throwing request-scoped binding maps like a handler throw.
    @Test func scopedControllerScopeEntryInsideDoWhenMapped() {
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/me")
            @ErrorResponse(Unauthenticated.self, .unauthorized)
            struct Me {
                @Get
                @JSONResponse
                func me() async throws -> Profile {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/me",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        let generated = rendered.source
        let doOpen = generated.range(of: "do {")
        let scopeEntry = generated.range(
            of: "let (wireMVCController, wireMVCScopeTeardown) = try await self._wireEnterScope(request)"
        )
        #expect(doOpen != nil && scopeEntry != nil)
        #expect(doOpen!.lowerBound < scopeEntry!.lowerBound)  // scope entry is inside the do
    }

    // MARK: - @ErrorResponse diagnostics

    @Test func untypedClosureParameterIsDiagnosed() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get @JSONResponse
                @ErrorResponse({ e in .status(.internalServerError) })
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseClosureNeedsTypedParameter = $0.message { return true } else { return false }
            }
        )
    }

    @Test func unresolvedStaticReferenceIsDiagnosed() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get @JSONResponse
                @ErrorResponse(SharedErrors.handleNotFound)
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseUnresolvedMapping = $0.message { return true } else { return false }
            }
        )
    }

    @Test func duplicateErrorTypeAtOneScopeIsDiagnosed() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            @ErrorResponse(NotFound.self, .gone)
            struct Users {
                @Get @JSONResponse
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseDuplicateType = $0.message { return true } else { return false }
            }
        )
    }

    @Test func catchAllNotLastIsDiagnosed() {
        let source = """
            @Controller("/users")
            @ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get @JSONResponse
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseCatchAllNotLast = $0.message { return true } else { return false }
            }
        )
    }

    // MARK: - @Middleware classification (factory / by-type / by-key)

    /// Controller-scope wraps outer, route-scope inner. `.self` arguments are graph bindings injected by
    /// type — folded as `self._wire<Type>`, never constructed inline.
    @Test func controllerAndRouteByTypeMiddlewareOrder() {
        let source = """
            @Controller("/x")
            @Middleware(ControllerGate.self)
            struct Gated {
                @Middleware(RouteGate.self)
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: []
        )
        #expect(rendered.source.contains("self._wireControllerGate"))
        #expect(rendered.source.contains("self._wireRouteGate"))
        let controllerIndex = rendered.source.range(of: "self._wireControllerGate")
        let routeIndex = rendered.source.range(of: "self._wireRouteGate")
        #expect(controllerIndex != nil && routeIndex != nil)
        #expect(controllerIndex!.lowerBound < routeIndex!.lowerBound)
        #expect(rendered.source.contains("try await self._wireSubject.f()"))
    }

    /// A key that is *not* a `@Factory` template is a graph binding — folded as `self._wire<sanitised key>`,
    /// distinct from the factory `create` call.
    @Test func middlewareBindingKeyFold() {
        let source = """
            @Controller("/x")
            @Middleware(Gates.primary)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: []
        )
        #expect(rendered.source.contains("self._wireGates_primary"))
        #expect(!rendered.source.contains("_wireFactory_"))
        #expect(!rendered.source.contains(".create("))
    }

    @Test func rawRoutePassthrough() {
        let source = """
            @Controller("/users")
            struct Raw {
                @Get("/events")
                @RawRoute
                func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "builder.register(method: .get, path: \"/users/events\") { _, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.events(responseSender: responseSender)"))
    }

    /// `@RawRoute(.responseSender)` binds the parameter to the register closure's `responseSender` by the
    /// explicit role — regardless of the parameter's *type*, so a transformed sender (a middleware's
    /// `MultiPartSender<S>`) that constraint-inference can't name still binds.
    @Test func rawRouteExplicitResponseSenderRole() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "builder.register(method: .post, path: \"/uploads/multipart\") { _, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.upload(responseSender: responseSender)"))
    }

    /// Multiple explicit roles bind positionally, in order.
    @Test func rawRouteExplicitRolesBindPositionally() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.request, .responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    _ request: HTTPRequest,
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        // request is used (not `_`) since a role names it; the call binds both by their labels.
        #expect(
            rendered.source.contains(
                "builder.register(method: .post, path: \"/uploads/multipart\") { request, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.upload(request, responseSender: responseSender)"))
    }

    @Test func rawRouteRoleCountMismatchIsDiagnosed() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    _ request: HTTPRequest,
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .rawRouteRoleCountMismatch = $0.message { return true } else { return false }
            }
        )
    }

    // MARK: - Subject-accessor seam

    /// The witness varies only by the subject accessor — swapping `_wireSubject` for another field leaves
    /// the register/bind/encode/fold logic identical (it comes from the one generator, parameterised).
    @Test func witnessVariesOnlyBySubjectAccessor() {
        let source = """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """
        let proxyWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "_wireSubject")
        let otherWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "controller")
        #expect(proxyWitness.replacingOccurrences(of: "self._wireSubject", with: "self.controller") == otherWitness)
    }

    @Test func subjectAccessorIsTheStructuralHalfContract() {
        // Meets WireGen's `_wireSubject` field (WireGenCore.contributorProxySubjectFieldName).
        #expect(contributorProxySubjectAccessor == "_wireSubject")
    }

    // MARK: - Diagnostics (route-shape validation, anchored)

    @Test func unannotatedParameterIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller
                struct C {
                    @Get("/x")
                    @JSONResponse
                    func f(id: String) -> Int { 0 }
                }
                """
            ),
            pathPrefix: "",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.count == 1)
        #expect(
            rendered.diagnostics.first?.message.message
                == "handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header"
        )
    }

    @Test func pathPlaceholderMismatchIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller("/users")
                struct C {
                    @Get
                    @JSONResponse
                    func f(@Path id: String) -> Int { 0 }
                }
                """
            ),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.first?.message.message
                == "@Path 'id' has no matching '{id}' placeholder in the route path \"/users\""
        )
    }

    @Test func rawRouteMissingSenderIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller
                struct C {
                    @Get("/x")
                    @RawRoute
                    func f(_ request: HTTPRequest) async throws {
                    }
                }
                """
            ),
            pathPrefix: "",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.first?.message.message
                == "@RawRoute handler 'f' must take the response sender (a parameter generic over HTTPResponseSender, or bound via @RawRoute(.responseSender)) to write its response"
        )
    }

    // MARK: - File-level generation (the tool's core)

    @Test func generatesSortedExtensionsWithImports() {
        let result = generateRouteContributors(files: [
            (
                "Controllers.swift",
                """
                import Domain

                @Controller("/b")
                struct Beta {
                    @Get @JSONResponse func g() -> Int { 0 }
                }

                @Controller("/a")
                struct Alpha {
                    @Get @JSONResponse func g() -> Int { 0 }
                }
                """
            )
        ])
        #expect(result.diagnostics.isEmpty)
        // Header + propagated import + WireMVC import.
        #expect(result.source.hasPrefix("// Generated by WireMVCRouteGen — do not edit."))
        #expect(result.source.contains("import Domain"))
        #expect(result.source.contains("import WireMVC"))
        // Extensions emitted for both, sorted by controller name (Alpha before Beta).
        let alpha = result.source.range(of: "extension _WireRouteContributor_Alpha")
        let beta = result.source.range(of: "extension _WireRouteContributor_Beta")
        #expect(alpha != nil && beta != nil)
        #expect(alpha!.lowerBound < beta!.lowerBound)
    }

    /// A controller in one file may fold a `@Factory` template declared in another: the tool collects
    /// factory keys across every input source before folding any witness, so the cross-file `@Middleware`
    /// still classifies as a factory (its `create` call), not a graph binding.
    @Test func factoryKeyDeclaredInAnotherFileIsClassifiedAsFactory() {
        let result = generateRouteContributors(files: [
            (
                "Middleware.swift",
                """
                @Factory(Keys.session)
                @MiddlewareFactory
                struct SessionMiddleware {}
                """
            ),
            (
                "Controller.swift",
                """
                @Controller("/x")
                @Middleware(Keys.session)
                struct C {
                    @Get @ResponseStatus(.noContent) func f() async throws {}
                }
                """
            ),
        ])
        #expect(result.diagnostics.isEmpty)
        #expect(
            result.source.contains(
                "self._wireFactory_Keys_session.create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
    }

    @Test func fileWithNoControllersEmitsHeaderOnly() {
        let result = generateRouteContributors(files: [("Empty.swift", "struct NotAController {}")])
        #expect(result.diagnostics.isEmpty)
        #expect(!result.source.contains("extension"))
        #expect(result.source.contains("import WireMVC"))
    }

    @Test func fileLevelDiagnosticCarriesLocation() {
        let result = generateRouteContributors(files: [
            (
                "Bad.swift",
                """
                @Controller
                struct C {
                    @Get("/x")
                    @JSONResponse
                    func f(id: String) -> Int { 0 }
                }
                """
            )
        ])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.location.line == 5)
    }
}
