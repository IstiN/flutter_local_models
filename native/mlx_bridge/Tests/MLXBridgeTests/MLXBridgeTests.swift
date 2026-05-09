import XCTest
@testable import MLXBridge

final class MLXBridgeTests: XCTestCase {
    func testRuntimeSummaryJsonEncodesExpectedShape() throws {
        let json = try MLXBridge.runtimeSummaryJson()
        XCTAssertTrue(json.contains("\"bridgeVersion\""))
        XCTAssertTrue(json.contains("\"mlxFocused\":true"))
    }

    func testRuntimeSummaryUsesMetalProbe() {
        let summary = MLXBridge.runtimeSummary()
        XCTAssertTrue(summary.ffiEnabled)
        XCTAssertTrue(summary.mlxFocused)
    }
}
