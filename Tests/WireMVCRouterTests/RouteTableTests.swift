import HTTPTypes
import Testing

@testable import WireMVCRouter

/// The router's path-matching core (`RouteTable`) tested without the proposal server's request/response
/// machinery. Pins v1 semantics: linear scan, first-registered-wins, `{name}` parameters, query
/// stripping, segment-count matching. Production hardening (radix, 405-vs-404, precedence,
/// trailing-slash policy, catch-all) is tracked in Documentation/Notes/WireMVCRouter.md.
@Suite("RouteTable — v1 linear matching")
struct RouteTableTests {

    @Test func literalMatchBindsNoParameters() {
        var table = RouteTable()
        #expect(table.add(method: .get, path: "/health") == 0)
        let match = table.resolve(method: .get, path: "/health")
        #expect(match?.index == 0)
        #expect(match?.parameters.isEmpty == true)
    }

    @Test func pathParameterBinds() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users/{id}")
        let match = table.resolve(method: .get, path: "/users/42")
        #expect(match?.index == 0)
        #expect(match?.parameters["id"].map(String.init) == "42")
    }

    @Test func multipleParametersBind() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/a/{x}/b/{y}")
        let match = table.resolve(method: .get, path: "/a/1/b/2")
        #expect(match?.parameters["x"].map(String.init) == "1")
        #expect(match?.parameters["y"].map(String.init) == "2")
    }

    @Test func noMatchReturnsNil() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users/{id}")
        #expect(table.resolve(method: .get, path: "/posts/1") == nil)
    }

    @Test func methodMismatchReturnsNil() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users")
        #expect(table.resolve(method: .post, path: "/users") == nil)
    }

    @Test func segmentCountMismatchReturnsNil() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users/{id}")
        #expect(table.resolve(method: .get, path: "/users") == nil)
    }

    @Test func queryStringIsIgnored() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users/{id}")
        let match = table.resolve(method: .get, path: "/users/42?trace=abc")
        #expect(match?.parameters["id"].map(String.init) == "42")
    }

    @Test func firstRegisteredWins() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users/{id}")
        _ = table.add(method: .get, path: "/users/{name}")
        // Both templates match "/users/ada"; v1 returns the first registered (precedence is a
        // tracked hardening item).
        #expect(table.resolve(method: .get, path: "/users/ada")?.index == 0)
    }

    @Test func indexTracksMatchedRoute() {
        var table = RouteTable()
        _ = table.add(method: .get, path: "/a")
        _ = table.add(method: .post, path: "/b")
        _ = table.add(method: .get, path: "/c/{id}")
        #expect(table.resolve(method: .post, path: "/b")?.index == 1)
        #expect(table.resolve(method: .get, path: "/c/9")?.index == 2)
    }

    @Test func trailingSlashMatchesInV1() {
        // v1: empty path segments are omitted, so "/users/" and "/users" are equivalent. A
        // trailing-slash *policy* is a tracked hardening item.
        var table = RouteTable()
        _ = table.add(method: .get, path: "/users")
        #expect(table.resolve(method: .get, path: "/users/")?.index == 0)
    }
}
