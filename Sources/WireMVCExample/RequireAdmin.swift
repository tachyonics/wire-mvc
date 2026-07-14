import WireMVC

/// A route-scope gate (Model B). If the `x-admin` header isn't `true`, this middleware *is* the one that
/// handles the request: it writes a 403 itself (consuming the sender), and the box becomes `.responded`
/// so the handler is skipped. It still calls `next` — every middleware runs — it just hands `next` a
/// box that's already been responded to.
struct RequireAdmin<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let isAdmin = input.peekedRequest.headerFields[HTTPField.Name("x-admin")!] == "true"
        guard input.isPending, !isAdmin else {
            return try await next(input)
        }
        return try await next(
            input.responding { sender in
                var writer = sender
                try await writer.sendAndFinish(HTTPResponse(status: .forbidden))
            }
        )
    }
}
