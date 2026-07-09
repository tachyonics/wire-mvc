import Wire
import WireMVC

// A WireMVC controller in its natural declarative shape. `@Singleton` makes it a graph
// binding; `@Controller` walks these routes and generates the `TransportContributor` witness
// (the extension is macro-generated), and its `@Contributes` alias collates the controller so
// `Wire.bootstrap()` + `WireMVC.apply` register its routes.
@Singleton
@Controller("/users")
struct UsersController: Sendable {
    @Inject var store: UserStore

    @Get("/{id}")
    @JSONResponse
    func getUser(@Path id: String) async throws -> User {
        try store.find(id)
    }

    @Post
    @JSONResponse(status: .created)
    func create(@JSONBody new: NewUser) async throws -> User {
        store.create(new)
    }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    func delete(@Path id: String) async throws {
        store.delete(id)
    }

    @Get
    @JSONResponse
    func list(
        @Query limit: Int = 10,  // defaulted @Query
        @Query cursor: String?,  // optional @Query
        @Header("x-trace") trace: String?  // optional @Header
    ) async throws -> Listing {
        Listing(limit: limit, cursor: cursor, trace: trace, users: store.list(limit: limit))
    }
}
