struct User: Codable, Sendable, Equatable {
    let id: String
    let name: String
}

struct NewUser: Codable, Sendable {
    let name: String
}

/// Echoes the bound query/header values back, so the example can assert they were actually
/// received (not just that their absence is tolerated).
struct Listing: Codable, Sendable, Equatable {
    let limit: Int
    let cursor: String?
    let trace: String?
    let users: [User]
}

/// Stands in for an `@Inject`ed dependency Wire would construct. Canned so the example
/// stays focused on routing/codegen, not state.
struct UserStore: Sendable {
    struct NotFound: Error {}

    func find(_ id: String) throws -> User {
        guard id == "42" else { throw NotFound() }
        return User(id: id, name: "Ada")
    }

    func create(_ new: NewUser) -> User { User(id: "99", name: new.name) }
    func delete(_ id: String) {}
    func list(limit: Int) -> [User] {
        (0..<limit).map { User(id: "u\($0)", name: "user-\($0)") }
    }
}
