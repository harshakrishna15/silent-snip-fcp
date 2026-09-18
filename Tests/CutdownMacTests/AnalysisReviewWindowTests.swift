import XCTest
@testable import CutdownMac

final class AnalysisReviewWindowTests: XCTestCase {
    func testReviewSurvivesMissingEffectViewAndRejectsOtherJobsAndOldPolls() {
        let id = UUID()
        var state = AnalysisReviewWindowState()
        state.begin(id)
        let complete = ReviewResponse(request: id, revision: 5, state: "review", message: "Ready", canApply: true)
        XCTAssertTrue(state.accept(complete))
        XCTAssertFalse(state.accept(ReviewResponse(request: UUID(), revision: 100, state: "failed", message: "Unrelated")))
        XCTAssertFalse(state.accept(ReviewResponse(request: id, revision: 4, state: "analyzing", message: "Old")))
        XCTAssertFalse(state.accept(complete), "Status polls must not reopen a dismissed window")
        XCTAssertEqual(state.response, complete)
    }

    func testNewAnalysisDropsThePreviousActionableReview() {
        let previous = UUID(), next = UUID()
        var state = AnalysisReviewWindowState()
        state.begin(previous)
        XCTAssertTrue(state.accept(ReviewResponse(request: previous, revision: 10, state: "review", message: "Ready", canApply: true)))
        state.begin(next)
        XCTAssertNil(state.response)
        XCTAssertFalse(state.accept(ReviewResponse(request: previous, revision: 11, state: "review", message: "Old review", canApply: true)))
        XCTAssertTrue(state.accept(ReviewResponse(request: next, revision: 1, state: "analyzing", message: "Starting")))
        XCTAssertFalse(state.response!.canApply)
    }
}
