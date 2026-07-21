import Wire
import WireMVC

// One app-scoped controller. `@Singleton @Controller` is all it needs — WireMVC collates it and the
// generated `@main` registers it. `GET /hello/{name}` → `{"message":"Hello, {name}!"}`.

@Singleton
@Controller("/hello")
struct HelloController {
    @Inject let greeter: Greeter

    @Get("/{name}")
    @JSONResponse
    func hello(@Path name: String) -> Greeting {
        Greeting(message: greeter.greet(name))
    }
}

struct Greeting: Codable, Sendable {
    let message: String
}
