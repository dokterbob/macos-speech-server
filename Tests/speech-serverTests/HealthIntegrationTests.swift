import XCTVapor
import XCTest

@testable import speech_server

final class HealthIntegrationTests: XCTestCase {
    struct HealthPayload: Content {
        let status: String
        let ready: Bool
    }

    func testHealthReportsReadyAfterModelsLoad() async throws {
        let app = try await sharedTestApp()
        try await app.test(.GET, "/health") { response async throws in
            XCTAssertEqual(response.status, .ok)
            let health = try response.content.decode(HealthPayload.self)
            XCTAssertEqual(health.status, "ok")
            XCTAssertTrue(health.ready)
        }
    }
}
