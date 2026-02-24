import Vapor

struct RequestLoggingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        let path = request.url.path.removingPercentEncoding ?? request.url.path
        request.logger.notice("\(request.method) \(path) \(response.status.code)")
        return response
    }
}
