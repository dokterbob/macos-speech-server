import Vapor

func routes(_ app: Application) throws {
    let speechController = SpeechController()
    let transcriptionController = TranscriptionController()

    // /audio/* routes
    try app.register(collection: speechController)
    try app.register(collection: transcriptionController)

    // /v1/audio/* mirror routes
    let v1 = app.grouped("v1")
    try v1.register(collection: speechController)
    try v1.register(collection: transcriptionController)
}
