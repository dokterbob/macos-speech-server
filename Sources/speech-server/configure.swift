import Vapor

func configure(_ app: Application) throws {
    app.middleware = Middlewares()
    app.middleware.use(OpenAIErrorMiddleware())

    try routes(app)
}
