import XCTest
@testable import CutdownMac

final class AnalyzeRequestTests: XCTestCase {
    private let id = "A138C701-5D3B-4367-AD59-7043D15C39C5"

    func testParsesInspectorSettings() throws {
        let request = try AnalyzeRequest(url: URL(string: "cutdown://analyze?request=\(id)&threshold=-36&minimum=0.5&before=0.08&after=0.2")!)
        XCTAssertEqual(request.settings.beforeSpeechPadding, 0.08)
        XCTAssertEqual(request.settings.afterSpeechPadding, 0.2)
        XCTAssertEqual(request.settings.thresholdDBFS, -36)
    }

    func testRejectsInvalidOrDuplicateArguments() {
        for query in [
            "request=\(id)&threshold=-40&minimum=0.5&before=0.1&after=0.1&after=0.2",
            "request=\(id)&threshold=nan&minimum=0.5&before=0.1&after=0.1",
            "request=\(id)&threshold=-40&minimum=0.5&before=-1&after=0.1",
            "request=\(id)&threshold=-40&minimum=0.5&before=0.1&after=0.1&apply=true",
            "threshold=-40&minimum=0.5&before=0.1&after=0.1"
        ] {
            XCTAssertThrowsError(try AnalyzeRequest(url: URL(string: "cutdown://analyze?\(query)")!))
        }
    }

    func testRejectsUnrelatedActions() {
        XCTAssertThrowsError(try AnalyzeRequest(url: URL(string: "cutdown://apply?request=\(id)&threshold=-40&minimum=0.5&before=0.1&after=0.1")!))
    }
}
