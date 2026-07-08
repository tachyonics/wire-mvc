import HTTPTypes
import OpenAPIRuntime
import WireMVC

// A WireMVC controller in its natural declarative shape. `@Controller` walks these routes and
// generates the `TransportContributor` witness (the extension below is macro-generated). In a
// graph-integrated app this would also be `@Singleton` and collated by Wire; here it's
// constructed directly in main.swift to prove the macro + witness in isolation.
@Controller("/users")
struct UsersController: Sendable {
    let store = UserStore()

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
}
