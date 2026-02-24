import Vapor

struct OpenAIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError {
            return makeErrorResponse(
                status: abort.status,
                message: abort.reason,
                type: "invalid_request_error",
                on: request
            )
        } catch {
            request.logger.error("Unhandled error: \(String(reflecting: error))")
            return makeErrorResponse(
                status: .internalServerError,
                message: error.localizedDescription,
                type: "server_error",
                on: request
            )
        }
    }

    private func makeErrorResponse(
        status: HTTPResponseStatus,
        message: String,
        type: String,
        on request: Request
    ) -> Response {
        let body = OpenAIErrorResponse(
            error: OpenAIErrorDetail(
                message: message,
                type: type,
                param: nil,
                code: nil
            )
        )
        let response = Response(status: status)
        do {
            try response.content.encode(body, as: .json)
        } catch {
            response.body = .init(string: #"{"error":{"message":"Internal Server Error","type":"server_error","param":null,"code":null}}"#)
            response.headers.contentType = .json
        }
        return response
    }
}
