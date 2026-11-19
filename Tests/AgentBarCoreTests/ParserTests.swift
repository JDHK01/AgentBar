import AgentBarCore
import Foundation
import XCTest

final class ParserTests: XCTestCase {
    func testHighRiskMatcher() {
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "rm -rf .build && swift build"), "rm -rf")
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "git push --force origin main"), "git push --force")
        XCTAssertNil(HookApprovalManager.matchedHighRiskRule(in: "swift test"))
    }
}
