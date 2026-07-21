import HTTPTypes
import Testing

@testable import WireMVCRouter

/// The router's path-segment trie (`RouteTrie` → `FrozenRouteTrie`) tested without the proposal
/// server's request/response machinery. Pins the matching semantics: `{name}` parameters, query
/// stripping, segment-exact matching, **literal-before-parameter** precedence, first-registered-wins
/// per node, and binary-searched literal children after freeze. Further hardening (405-vs-404,
/// full precedence, trailing-slash policy, catch-all) is tracked in Documentation/Notes/WireMVCRouter.md.
@Suite("RouteTrie — segment-trie matching")
struct RouteTrieTests {

    @Test func literalMatchBindsNoParameters() {
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/health")
        let match = trie.freeze().resolve(method: .get, path: "/health")
        #expect(match?.index == index)
        #expect(match?.parameters.isEmpty == true)
    }

    @Test func pathParameterBinds() {
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users/42")
        #expect(match?.index == index)
        #expect(match?.parameters["id"].map(String.init) == "42")
    }

    @Test func multipleParametersBind() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/a/{x}/b/{y}")
        let match = trie.freeze().resolve(method: .get, path: "/a/1/b/2")
        #expect(match?.parameters["x"].map(String.init) == "1")
        #expect(match?.parameters["y"].map(String.init) == "2")
    }

    @Test func noMatchReturnsNil() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .get, path: "/posts/1") == nil)
    }

    @Test func methodMismatchReturnsNil() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze().resolve(method: .post, path: "/users") == nil)
    }

    @Test func prefixWithoutRouteReturnsNil() {
        // "/users/{id}" registers a route at the {id} node, not the /users node — so GET /users has
        // no route and misses (segment-exact matching).
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .get, path: "/users") == nil)
    }

    @Test func queryStringIsIgnored() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users/42?trace=abc")
        #expect(match?.parameters["id"].map(String.init) == "42")
    }

    @Test func literalBeatsParameter() {
        // Static-before-param precedence: /users/me matches the literal even though /users/{id} exists.
        var trie = RouteTrie()
        let me = trie.insert(method: .get, path: "/users/me")
        let byId = trie.insert(method: .get, path: "/users/{id}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/me")?.index == me)
        let param = frozen.resolve(method: .get, path: "/users/42")
        #expect(param?.index == byId)
        #expect(param?.parameters["id"].map(String.init) == "42")
    }

    @Test func distinctMethodsAtSameNodeDispatchSeparately() {
        var trie = RouteTrie()
        let get = trie.insert(method: .get, path: "/users/{id}")
        let delete = trie.insert(method: .delete, path: "/users/{id}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/9")?.index == get)
        #expect(frozen.resolve(method: .delete, path: "/users/9")?.index == delete)
    }

    @Test func binarySearchFindsAmongManyLiterals() {
        // Exercises the frozen node's sorted-array binary search across several literal siblings.
        var trie = RouteTrie()
        var indices: [String: Int] = [:]
        for name in ["alpha", "bravo", "charlie", "delta", "echo"] {
            indices[name] = trie.insert(method: .get, path: "/\(name)")
        }
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/charlie")?.index == indices["charlie"])
        #expect(frozen.resolve(method: .get, path: "/echo")?.index == indices["echo"])
        #expect(frozen.resolve(method: .get, path: "/foxtrot") == nil)
    }

    @Test func trailingSlashMatchesInV1() {
        // v1: empty path segments are omitted, so "/users/" and "/users" are equivalent. A
        // trailing-slash *policy* is a tracked hardening item.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze().resolve(method: .get, path: "/users/")?.index == index)
    }
}
