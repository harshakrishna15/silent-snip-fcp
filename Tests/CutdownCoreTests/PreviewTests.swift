import XCTest
@testable import CutdownCore

final class PreviewTests: XCTestCase {
    private let job = UUID(uuidString: "B9466DE9-4680-4AA1-A826-C6ECF564153C")!

    private func document(markers: String = "", extra: String = "", targetName: String = "Recording",
                          targetOffset: String = "0s", projectDuration: String = "10s", hasVideo: Bool = false) throws -> TimelineDocument {
        try TimelineParser.parse(data: Data("""
        <fcpxml version="1.14"><resources>
        <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
        <asset id="r2" start="0s" duration="10s" hasVideo="\(hasVideo ? 1 : 0)" hasAudio="1" format="r1">
        <media-rep src="file:///private/tmp/cutdown-test.wav"/></asset></resources>
        <library><event><project name="Test" uid="project-1"><sequence format="r1" duration="\(projectDuration)" tcStart="0s">
        <spine><asset-clip ref="r2" name="\(targetName)" offset="\(targetOffset)" start="0s" duration="10s" audioRole="dialogue">
        \(markers)</asset-clip>\(extra)</spine></sequence></project></event></library></fcpxml>
        """.utf8))
    }

    private func review(_ document: TimelineDocument, range: TimeRange = TimeRange(start: RationalTime(2), end: RationalTime(3))) throws -> ReviewPlan {
        let target = try document.selectedTarget(TimelineSelection(timelineRange: TimeRange(start: .zero, end: RationalTime(10))), requireExistingMedia: false)
        return try ReviewPlan(jobID: job, document: document, target: target,
            analysis: SilenceAnalysisResult(candidates: [range], disposition: .cuts))
    }

    func testMarkersUseFirstAndLastRemovedFrames() throws {
        let doc = try document()
        let preview = try MarkerPreview(review: review(doc), existingMarkers: [])
        XCTAssertEqual(preview.additions.map(\.timelinePosition), [RationalTime(2), RationalTime(89, 30)])
        XCTAssertEqual(preview.additions.map(\.value), ["Cutdown 01 Start", "Cutdown 01 End"])
        XCTAssertTrue(preview.collisions.isEmpty)
    }

    func testOneFrameRangeUsesOneCombinedMarker() throws {
        let doc = try document()
        let plan = try review(doc, range: TimeRange(start: RationalTime(2), end: RationalTime(61, 30)))
        let preview = try MarkerPreview(review: plan, existingMarkers: [])
        XCTAssertEqual(preview.additions.count, 1)
        XCTAssertEqual(preview.additions[0].value, "Cutdown 01 Start/End")
    }

    func testCollisionPreservesExistingUserMarker() throws {
        let doc = try document(markers: "<marker start=\"2s\" duration=\"1/30s\" value=\"User marker\"/>")
        let preview = try MarkerPreview(review: review(doc), existingMarkers: doc.markers)
        XCTAssertEqual(preview.additions.count, 1)
        XCTAssertEqual(preview.collisions.count, 1)
        XCTAssertEqual(preview.collisions[0].existingMarkers[0].value, "User marker")
    }

    func testCheckboxChoicesPreservedOnlyWhenRangesMatch() throws {
        let doc = try document()
        var plan = try review(doc)
        try plan.setIncluded(false, cutID: plan.cuts[0].id)
        let unchanged = try SilenceAnalysisResult(candidates: plan.cuts.map(\.range), disposition: .cuts)
        XCTAssertFalse(try plan.recalculate(unchanged, document: doc))
        XCTAssertFalse(plan.cuts[0].included)
        let changed = try SilenceAnalysisResult(candidates: [TimeRange(start: RationalTime(21, 10), end: RationalTime(3))], disposition: .cuts)
        XCTAssertTrue(try plan.recalculate(changed, document: doc))
        XCTAssertTrue(plan.cuts[0].included)
    }

    func testUserMarkerChangesInvalidateReview() throws {
        let doc = try document()
        var plan = try review(doc)
        let changed = try document(markers: "<marker start=\"4s\" duration=\"1/30s\" value=\"A user note\"/>")
        let analysis = try SilenceAnalysisResult(candidates: plan.cuts.map(\.range), disposition: .cuts)
        XCTAssertThrowsError(try plan.recalculate(analysis, document: changed))
    }

    func testOwnershipSurvivesChildIndexShiftButNotMarkerEditing() throws {
        let baseline = try document()
        let draft = try MarkerPreview(review: review(baseline), existingMarkers: []).additions[0]
        let ownedXML = "<marker start=\"2s\" duration=\"1/30s\" value=\"\(draft.value)\" note=\"\(draft.note)\"/>"
        let inserted = try document(markers: ownedXML)
        var manifest = MarkerOwnershipManifest(jobID: job, document: baseline)
        try manifest.record(draft, in: inserted)
        let shifted = try document(markers: "<marker start=\"1s\" duration=\"1/30s\" value=\"User\"/>" + ownedXML)
        let resolution = try manifest.resolve(in: shifted)
        XCTAssertEqual(resolution.exactMatches.count, 1)
        XCTAssertTrue(resolution.unresolved.isEmpty)
        XCTAssertNotEqual(inserted.markers[0].id, resolution.exactMatches[0].id)
        let edited = try document(markers: ownedXML.replacingOccurrences(of: draft.value, with: "My edited marker"))
        let editedResolution = try manifest.resolve(in: edited)
        XCTAssertTrue(editedResolution.exactMatches.isEmpty)
        XCTAssertEqual(editedResolution.unresolved.count, 1)
    }

    func testWholeClipRemovalCannotBeIncluded() throws {
        let doc = try document()
        var plan = try review(doc, range: TimeRange(start: .zero, end: RationalTime(10)))
        XCTAssertFalse(plan.cuts[0].isEligible)
        XCTAssertFalse(plan.cuts[0].included)
        XCTAssertThrowsError(try plan.setIncluded(true, cutID: plan.cuts[0].id))
        XCTAssertTrue(try MarkerPreview(review: plan, existingMarkers: []).additions.isEmpty)
    }

    func testOwnershipDoesNotFollowAParentClipMovedOnTheTimeline() throws {
        let baseline = try document()
        let draft = try MarkerPreview(review: review(baseline), existingMarkers: []).additions[0]
        let markerXML = "<marker start=\"2s\" duration=\"1/30s\" value=\"\(draft.value)\" note=\"\(draft.note)\"/>"
        var manifest = MarkerOwnershipManifest(jobID: job, document: baseline)
        try manifest.record(draft, in: document(markers: markerXML))
        let moved = try document(markers: markerXML, targetOffset: "1s", projectDuration: "11s")
        XCTAssertEqual(moved.markers.first?.sourcePosition, draft.sourcePosition)
        XCTAssertNotEqual(moved.markers.first?.timelinePosition, draft.timelinePosition)
        let resolution = try manifest.resolve(in: moved)
        XCTAssertTrue(resolution.exactMatches.isEmpty)
        XCTAssertEqual(resolution.unresolved.count, 1)
    }

    func testReviewRejectsForeignTargetWithOtherwiseIdenticalSelectionBounds() throws {
        let doc = try document()
        let foreign = try document(targetName: "Another recording")
        let target = try XCTUnwrap(foreign.clips.first)
        let analysis = try SilenceAnalysisResult(candidates: [TimeRange(start: RationalTime(2), end: RationalTime(3))], disposition: .cuts)
        XCTAssertThrowsError(try ReviewPlan(jobID: job, document: doc, target: target, analysis: analysis)) { error in
            guard case ReviewError.invalidTarget = error else { return XCTFail("Expected exact target membership validation: \(error)") }
        }
    }

    func testReviewRejectsRetimedAndConnectedTargetsEvenWhenCallerBypassesSelection() throws {
        let retimed = try document(markers: "<timeMap/>")
        let connected = try document(markers: "<asset-clip ref=\"r2\" name=\"Connected\" lane=\"1\" offset=\"1s\" start=\"0s\" duration=\"4s\" audioRole=\"dialogue\"/>")
        let analysis = try SilenceAnalysisResult(candidates: [TimeRange(start: RationalTime(2), end: RationalTime(3))], disposition: .cuts)
        let retimedTarget = try XCTUnwrap(retimed.clips.first)
        let connectedTarget = try XCTUnwrap(connected.clips.first(where: { !$0.isPrimaryStoryline }))
        XCTAssertThrowsError(try ReviewPlan(jobID: job, document: retimed, target: retimedTarget, analysis: analysis))
        XCTAssertThrowsError(try ReviewPlan(jobID: job, document: connected, target: connectedTarget, analysis: analysis))
    }

    func testReviewRejectsVideoWithAudioEvenWhenCallerBypassesSelection() throws {
        let video = try document(hasVideo: true)
        let target = try XCTUnwrap(video.clips.first)
        let analysis = try SilenceAnalysisResult(candidates: [TimeRange(start: RationalTime(2), end: RationalTime(3))], disposition: .cuts)
        XCTAssertTrue(target.hasAudio && target.hasVideo)
        XCTAssertThrowsError(try ReviewPlan(jobID: job, document: video, target: target, analysis: analysis)) { error in
            guard case TimelineError.unsupportedTarget(let reasons) = error else { return XCTFail("Unexpected rejection: \(error)") }
            XCTAssertTrue(reasons.contains("Cutdown supports audio-only timeline clips; video clips with audio are not supported"))
        }
    }

    func testAdjacentCandidatesCannotCollectivelyDeleteTheWholeClip() throws {
        let doc = try document()
        let target = try XCTUnwrap(doc.clips.first)
        let analysis = try SilenceAnalysisResult(candidates: [
            TimeRange(start: .zero, end: RationalTime(4)),
            TimeRange(start: RationalTime(4), end: RationalTime(10))
        ], disposition: .cuts)
        XCTAssertThrowsError(try ReviewPlan(jobID: job, document: doc, target: target, analysis: analysis)) { error in
            guard case ReviewError.wholeClipCoverage = error else { return XCTFail("Expected aggregate whole-clip validation: \(error)") }
        }
        var existingReview = try review(doc)
        XCTAssertThrowsError(try existingReview.recalculate(analysis, document: doc))
        XCTAssertEqual(existingReview.selectedCuts.count, 1)
        XCTAssertEqual(existingReview.selectedCuts[0].range, TimeRange(start: RationalTime(2), end: RationalTime(3)))
    }

    func testReviewEncodingDoesNotExposeAnUnvalidatedDecodePath() throws {
        let plan = try review(document())
        let payload = try JSONEncoder().encode(plan)
        XCTAssertFalse(payload.isEmpty)
        let planType: Any.Type = ReviewPlan.self
        let cutType: Any.Type = ReviewCut.self
        XCTAssertFalse(planType is any Decodable.Type)
        XCTAssertFalse(cutType is any Decodable.Type)
    }
}
