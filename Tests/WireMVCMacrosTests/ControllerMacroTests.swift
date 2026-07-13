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
                        builder.register(method: .get, path: "/todos/{id}") { request, pathParameters, _, responseSender in
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
                        builder.register(method: .get, path: "/users/events") { _, _, _, responseSender in
                            try await self.events(responseSender: responseSender)
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
}
