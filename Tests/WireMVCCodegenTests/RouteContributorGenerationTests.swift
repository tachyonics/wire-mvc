import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// Phase A, A2 — the domain half of a route contributor. The `WireMVCRouteGen` tool (via `WireMVCCodegen`)
/// emits the `RouteContributor` witness as an `extension` on the plugin-emitted structural proxy, folding
/// the *same* route codegen the `@Controller` macro uses (verbs, `@Path`/… bindings, response modes,
/// `@RawRoute`, the `~Copyable` middleware fold) — so the two cannot drift. These tests pin the emitted
/// extension for every route shape and the diagnostics, and assert the witness matches the macro's
/// (differing only by the subject accessor `_wireSubject` vs `controller`).
@Suite("Route-contributor generation (A2)")
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

    private func witnessBody(_ source: String, pathPrefix: String, subjectAccessor: String) -> String {
        renderRegisterWireRoutesWitness(
            access: "", controller: controller(source), pathPrefix: pathPrefix, subjectAccessor: subjectAccessor
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
        let rendered = renderRouteContributorExtension(controller: controller(source), pathPrefix: "/todos")
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Todos: RouteContributor {
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
        let rendered = renderRouteContributorExtension(controller: controller(source), pathPrefix: "/x")
        #expect(
            rendered.source == """
                extension _WireRouteContributor_C: RouteContributor {
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
    /// response status. (The macro's own golden tests don't cover these binding shapes.)
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
        let rendered = renderRouteContributorExtension(controller: controller(source), pathPrefix: "/search")
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Search: RouteContributor {
                    func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout Builder) throws
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

    @Test func controllerAndRouteGenericMiddlewareOrder() {
        let source = """
            @Controller("/x")
            @Middleware(ControllerMiddleware<WireContext, WireReader, WireSender>.self)
            struct GenMw {
                @Middleware(RouteMiddleware<WireContext, WireReader, WireSender>.self)
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(controller: controller(source), pathPrefix: "/x")
        // Controller-outer, route-inner, both re-spelt over the builder's associated types.
        #expect(rendered.source.contains("ControllerMiddleware<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()"))
        #expect(rendered.source.contains("RouteMiddleware<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()"))
        let controllerIndex = rendered.source.range(of: "ControllerMiddleware<Builder")
        let routeIndex = rendered.source.range(of: "RouteMiddleware<Builder")
        #expect(controllerIndex != nil && routeIndex != nil)
        #expect(controllerIndex!.lowerBound < routeIndex!.lowerBound)
        #expect(rendered.source.contains("try await self._wireSubject.f()"))
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
        let rendered = renderRouteContributorExtension(controller: controller(source), pathPrefix: "/users")
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("builder.register(method: .get, path: \"/users/events\") { _, _, _, _, responseSender in"))
        #expect(rendered.source.contains("try await self._wireSubject.events(responseSender: responseSender)"))
    }

    // MARK: - Parity with the macro (drift guard)

    /// The witness the tool emits (`_wireSubject`) is the witness the macro emits (`controller`) with only
    /// the subject accessor changed — same register/bind/encode/fold logic, from the same generator. This
    /// asserts that directly: swapping the accessor makes the two bodies identical.
    @Test func witnessDiffersFromMacroOnlyBySubjectAccessor() {
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
        let toolWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "_wireSubject")
        let macroWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "controller")
        #expect(toolWitness.replacingOccurrences(of: "self._wireSubject", with: "self.controller") == macroWitness)
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
            pathPrefix: ""
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
            pathPrefix: "/users"
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
            pathPrefix: ""
        )
        #expect(
            rendered.diagnostics.first?.message.message
                == "@RawRoute handler 'f' must take the response sender (a parameter generic over HTTPResponseSender) to write its response"
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
