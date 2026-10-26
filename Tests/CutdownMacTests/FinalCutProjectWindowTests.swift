import XCTest
@testable import CutdownMac

final class FinalCutProjectWindowTests: XCTestCase {
    private func resolve(main: String?, windows: [String], workspaces: Set<String> = ["project"]) -> String? {
        FinalCutProjectWindow.resolve(main: main, windows: windows, equals: ==, isWorkspace: { workspaces.contains($0) })
    }

    func testMissingMainWindowFindsWorkspaceBehindEffectAndImportPanels() {
        XCTAssertEqual(resolve(main: nil, windows: ["effect", "import", "project", "viewer"]), "project")
        XCTAssertNil(resolve(main: nil, windows: ["effect", "import", "viewer"]))
    }

    func testInvalidMainWindowFallsBackWithoutRecheckingStaleElement() {
        var checked: [String] = []
        let window = FinalCutProjectWindow.resolve(main: "stale", windows: ["stale", "effect", "project"], equals: ==) {
            checked.append($0)
            return $0 == "project"
        }
        XCTAssertEqual(window, "project")
        XCTAssertEqual(checked, ["stale", "effect", "project"])
        XCTAssertEqual(resolve(main: "effect", windows: ["effect", "project"]), "project")
    }

    func testValidMainWindowPreservesHostChoiceWithoutScanningOtherWindows() {
        var checked: [String] = []
        let window = FinalCutProjectWindow.resolve(main: "project", windows: ["another"], equals: ==) {
            checked.append($0)
            return true
        }
        XCTAssertEqual(window, "project")
        XCTAssertEqual(checked, ["project"])
        XCTAssertEqual(resolve(main: "project", windows: []), "project")
    }

    func testFallbackRejectsMultipleProjectWorkspaces() {
        XCTAssertNil(resolve(main: nil, windows: ["project", "another"], workspaces: ["project", "another"]))
        XCTAssertNil(resolve(main: "effect", windows: ["project", "another"], workspaces: ["project", "another"]))
    }

    func testRepeatedWorkspaceReferencesDoNotCreateFalseAmbiguity() {
        XCTAssertEqual(resolve(main: nil, windows: ["effect", "project", "project"]), "project")
    }

    func testWindowDiscoveryIsBounded() {
        let windows = (0..<32).map { "panel\($0)" } + ["project"]
        XCTAssertNil(resolve(main: nil, windows: windows))
        XCTAssertNil(resolve(main: nil, windows: ["project"] + windows), "An incomplete scan cannot prove uniqueness")
    }

    func testOnlyTitledStandardNonmodalWindowsCanContainWorkspace() {
        XCTAssertTrue(FinalCutProjectWindow.isWorkspace(role: "AXWindow", subrole: "AXStandardWindow", modal: false, title: "Final Cut Pro"))
        XCTAssertTrue(FinalCutProjectWindow.isWorkspace(role: "AXWindow", subrole: "AXStandardWindow", modal: nil, title: "Final Cut Pro"))
        for (role, subrole, modal, title) in [
            ("AXWindow", "AXDialog", false, "Audio"),
            ("AXSheet", "AXStandardWindow", false, "Final Cut Pro"),
            ("AXWindow", "AXStandardWindow", true, "Final Cut Pro"),
            ("AXWindow", "AXStandardWindow", false, ""),
            ("AXWindow", nil, false, "Final Cut Pro"),
            (nil, "AXStandardWindow", false, "Final Cut Pro"),
            ("AXWindow", "AXStandardWindow", false, nil)
        ] as [(String?, String?, Bool?, String?)] {
            XCTAssertFalse(FinalCutProjectWindow.isWorkspace(role: role, subrole: subrole, modal: modal, title: title))
        }
    }
}
