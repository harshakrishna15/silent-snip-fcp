// Historical local-review transport fixture; the app no longer creates this window.
import Foundation
@testable import CutdownMac

/// Review ownership follows the helper job, not Final Cut's disposable AU view.
struct AnalysisReviewWindowState {
    private(set) var request: UUID?
    private(set) var response: ReviewResponse?

    mutating func begin(_ request: UUID) {
        self.request = request
        response = nil
    }

    mutating func accept(_ response: ReviewResponse) -> Bool {
        guard response.request == request,
              response.revision > (self.response?.revision ?? -1) else { return false }
        self.response = response
        return true
    }
}

