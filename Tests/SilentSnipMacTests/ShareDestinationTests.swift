import XCTest
import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import SilentSnipMac

final class ShareDestinationTests: XCTestCase {
    @MainActor func testShareDefinitionResolvesRenamedRuntimeClassesAndAssetKey() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Config/SilentSnip.sdef"))
        let definition = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let classes = try definition.nodes(forXPath: "//cocoa/@class").compactMap(\.stringValue)
        XCTAssertTrue(classes.contains("SilentSnipShareOpenCommand"))
        XCTAssertTrue(classes.contains("SilentSnipShareMakeCommand"))
        XCTAssertTrue(classes.contains("SilentSnipShareAsset"))
        for name in classes { XCTAssertNotNil(NSClassFromString(name), "Missing scripting class: \(name)") }
        let key = try XCTUnwrap(definition.nodes(forXPath: "//class[@name='application']/element/cocoa/@key").first?.stringValue)
        XCTAssertTrue(NSApplication.shared.responds(to: NSSelectorFromString(key)))
        let collection = key.prefix(1).uppercased() + key.dropFirst()
        XCTAssertTrue(NSApplication.shared.responds(to: NSSelectorFromString("valueIn\(collection)WithUniqueID:")))
    }

    private var completeXML: String {
        """
        <fcpxml version="1.14"><resources><format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="file:///fixture.wav"/></asset>
        </resources><library><event><project name="Project"><sequence format="f" duration="10s" tcStart="0s">
        <spine><asset-clip ref="a" offset="0s" start="0s" duration="10s" audioRole="dialogue"/></spine>
        </sequence></project></event></library></fcpxml>
        """
    }

    @MainActor func testClosedXMLDeliveryAvoidsThreeSecondWaitAndPreservesImmutableBytes() async throws {
        let manager = try manager(), xml = completeXML
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await manager.captureXML(projectName: "Project") {
            let asset = try manager.createAsset(name: "Project")
            _ = try self.write("Project.fcpxml", in: asset.directoryURL, contents: xml)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 1, "A complete closed XML does not need three seconds of guessed stability")
        let original = manager.assets[0].directoryURL.appendingPathComponent("Project.fcpxml")
        XCTAssertNotEqual(result, original)
        try Data("later producer write".utf8).write(to: original)
        XCTAssertEqual(try String(contentsOf: result), xml)
        print("Closed XML capture fixture: \(elapsed) seconds; includes parse, completion and immutable snapshot.")
    }

    @MainActor func testXMLFastPathWaitsForActualProducerClose() async throws {
        let manager = try manager()
        var closer: Task<Void, Error>?
        let started = ProcessInfo.processInfo.systemUptime
        _ = try await manager.captureXML(projectName: "Project", timeout: 2) {
            let asset = try manager.createAsset(name: "Project")
            let original = try self.write("Project.fcpxml", in: asset.directoryURL, contents: self.completeXML)
            let writer = try FileHandle(forWritingTo: original)
            closer = Task { try await Task.sleep(for: .milliseconds(250)); try writer.close() }
        }
        try await closer?.value
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.24)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    @MainActor func testLateHostCompletionIsReportedOnceOnlyForAnUnchangedFastSnapshot() async throws {
        let manager = try manager()
        manager.xmlSnapshotReader = { url in
            CompletedXMLSnapshot.read(url, probe: { _ in .exclusive }) { _ in true }
        }
        var callbacks = 0
        manager.onLateXMLCompletion = { directory in
            XCTAssertEqual(directory, manager.assets[0].directoryURL)
            callbacks += 1
        }
        _ = try await manager.captureXML(projectName: "Project") {
            let asset = try manager.createAsset(name: "Project")
            _ = try self.write("Project.fcpxml", in: asset.directoryURL, contents: self.completeXML)
        }
        XCTAssertEqual(callbacks, 0, "The snapshot is not a host activation event")
        let original = manager.assets[0].directoryURL.appendingPathComponent("Project.fcpxml")
        XCTAssertFalse(manager.handleOpen(urls: [manager.rootURL.appendingPathComponent("Other.fcpxml")]))
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(manager.handleOpen(urls: [original]))
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(manager.handleOpen(urls: [original]))
        XCTAssertEqual(callbacks, 1, "A duplicate cannot reclaim focus again")
    }

    @MainActor func testUnsupportedXMLCompletionCheckRetainsLegacyStabilityFallback() async throws {
        let manager = try manager()
        manager.xmlSnapshotReader = { _ in .unavailable }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await manager.captureXML(projectName: "Project", timeout: 5) {
            let asset = try manager.createAsset(name: "Project")
            _ = try self.write("Project.fcpxml", in: asset.directoryURL, contents: self.completeXML)
        }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 2.9)
        XCTAssertEqual(result.lastPathComponent, "Project.fcpxml")
    }

    @MainActor func testSymlinkedShareRootCannotRotateAnExternalLog() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LinkedShareTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let original = try write("events.jsonl", in: outside, contents: "User file")
        let alias = base.appendingPathComponent("Share Inbox")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let manager = ShareDestinationManager(rootURL: alias)
        _ = try manager.createAsset(name: "Project")
        XCTAssertEqual(try String(contentsOf: original), "User file")
    }

    @MainActor func testOnlyRequestOwnedCompletedRendersEnterTheCleanupInventory() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("StorageShareTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ShareDestinationManager(rootURL: root.appendingPathComponent("Share Inbox"))
        let receipt = try await manager.captureMedia(projectName: "Processed") {
            let asset = try manager.createAsset(name: "Processed")
            let xml = try self.write("Processed.fcpxml", in: asset.directoryURL)
            let audio = try self.write("Processed.wav", in: asset.directoryURL)
            XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        }
        let manual = try manager.createAsset(name: "User Export")
        let manualXML = try write("User Export.fcpxml", in: manual.directoryURL)
        let manualAudio = try write("User Export.wav", in: manual.directoryURL)
        XCTAssertTrue(manager.handleOpen(urls: [manualXML, manualAudio]))
        let report = StorageCleanup(root: root).clean(manual: true)
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.mediaURLs[0].path))
        for file in [receipt.xmlURL, manualXML, manualAudio] {
            XCTAssertEqual(try String(contentsOf: file), "fixture")
        }
    }

    @MainActor private func manager() throws -> ShareDestinationManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SilentSnipShareTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ShareDestinationManager(rootURL: directory)
    }

    private func write(_ name: String, in directory: URL, contents: String = "fixture") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @MainActor func testProgrammaticCaptureRequestsOnlyXMLAndBypassesLegacyReview() async throws {
        let manager = try manager()
        var legacyDeliveries = 0
        manager.onReceive = { _ in legacyDeliveries += 1 }
        let result = try await manager.captureXML(projectName: "Project") {
            let asset = try manager.createAsset(name: "Project")
            XCTAssertEqual(asset.locationInfo["hasMedia"] as? Bool, false)
            XCTAssertEqual(asset.locationInfo["hasDescription"] as? Bool, true)
            XCTAssertEqual(asset.libraryInfo["hasArchive"] as? Bool, false)
            let xml = try self.write("Project.fcpxml", in: asset.directoryURL)
            XCTAssertTrue(manager.handleOpen(urls: [xml]))
        }
        XCTAssertEqual(result.lastPathComponent, "Project.fcpxml")
        XCTAssertEqual(legacyDeliveries, 0)
    }

#if DEBUG
    @MainActor func testPrototypeDistinguishesAcceptedShareFromCompletedResponseWithinItsOwnRequest() async throws {
        let manager = try manager()
        XCTAssertFalse(manager.prototypeHostAcceptedShare(projectName: "Project"))
        XCTAssertFalse(manager.prototypeShareHasResponse(projectName: "Project"))
        _ = try await manager.captureXML(projectName: "Project") {
            XCTAssertFalse(manager.prototypeHostAcceptedShare(projectName: "Project"))
            let asset = try manager.createAsset(name: "Project")
            XCTAssertTrue(manager.prototypeHostAcceptedShare(projectName: "Project"))
            XCTAssertFalse(manager.prototypeHostAcceptedShare(projectName: "Other"))
            XCTAssertFalse(manager.prototypeShareHasResponse(projectName: "Project"))
            let xml = try self.write("Project.fcpxml", in: asset.directoryURL, contents: self.completeXML)
            XCTAssertTrue(manager.handleOpen(urls: [xml]))
            XCTAssertTrue(manager.prototypeShareHasResponse(projectName: "Project"))
            XCTAssertFalse(manager.prototypeShareHasResponse(projectName: "Other"))
        }
        XCTAssertFalse(manager.prototypeHostAcceptedShare(projectName: "Project"))
        XCTAssertFalse(manager.prototypeShareHasResponse(projectName: "Project"))
    }

    @MainActor func testLateCanceledResponseCannotAuthorizeAnotherPrototypeMenuAction() async throws {
        let manager = try manager()
        var pending: ShareDestinationAsset?
        do {
            _ = try await manager.captureXML(projectName: "Project") {
                pending = try manager.createAsset(name: "Project")
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let xml = try write("Project.fcpxml", in: XCTUnwrap(pending).directoryURL, contents: completeXML)
        XCTAssertTrue(manager.handleOpen(urls: [xml]))
        XCTAssertFalse(manager.prototypeHostAcceptedShare(projectName: "Project"))
        XCTAssertFalse(manager.prototypeShareHasResponse(projectName: "Project"))
    }
#endif

    @MainActor func testProgrammaticCaptureRejectsWrongProjectAndResetsAfterFailure() async throws {
        let manager = try manager()
        do {
            _ = try await manager.captureXML(projectName: "Expected") {
                _ = try manager.createAsset(name: "Other")
            }
            XCTFail("Wrong project must fail")
        } catch { XCTAssertEqual(error as? ShareDestinationError, .unknownDelivery) }
        let legacy = try manager.createAsset(name: "Other")
        XCTAssertTrue(legacy.requiresMedia)
    }

    @MainActor func testCanceledXMLDeliveryNeverStartsLegacyAudioAnalysis() async throws {
        let manager = try manager()
        var asset: ShareDestinationAsset?
        do {
            _ = try await manager.captureXML(projectName: "Project") {
                asset = try manager.createAsset(name: "Project")
                throw CancellationError()
            }
        } catch is CancellationError {}
        var received = false
        manager.onReceive = { _ in received = true }
        let xml = try write("Project.fcpxml", in: XCTUnwrap(asset).directoryURL)
        XCTAssertTrue(manager.handleOpen(urls: [xml]))
        XCTAssertFalse(received)
    }

    @MainActor func testProgrammaticCaptureAcceptsCompleteOwnedXMLWithoutOpenEvent() async throws {
        let manager = try manager()
        let xml = """
        <fcpxml version="1.14"><resources>
        <format id="f" frameDuration="1/30s"/>
        <asset id="a" start="0s" duration="10s" hasAudio="1"><media-rep kind="original-media" src="file:///test.wav"/></asset>
        </resources><library><event><project name="Project"><sequence format="f" duration="10s" tcStart="0s">
        <spine><asset-clip ref="a" offset="0s" start="0s" duration="10s" audioRole="dialogue"/></spine>
        </sequence></project></event></library></fcpxml>
        """
        let result = try await manager.captureXML(projectName: "Project", timeout: 5) {
            let asset = try manager.createAsset(name: "Project")
            _ = try self.write("Project.fcpxml", in: asset.directoryURL, contents: xml)
        }
        XCTAssertEqual(try String(contentsOf: result), xml)
        XCTAssertFalse(manager.assets[0].requiresMedia)
        var lateError: Error?
        manager.onFailure = { lateError = $0 }
        let original = manager.assets[0].directoryURL.appendingPathComponent("Project.fcpxml")
        XCTAssertTrue(manager.handleOpen(urls: [original]))
        XCTAssertNil(lateError)
        try Data("changed".utf8).write(to: original)
        XCTAssertTrue(manager.handleOpen(urls: [original]))
        XCTAssertEqual(lateError as? ShareDestinationError, .changedDelivery)
    }

    @MainActor func testOwnedMediaRequiresCompletionAndNeverBecomesLegacyAfterRestart() async throws {
        let manager = try manager()
        var deliveries = 0
        manager.onReceive = { _ in deliveries += 1 }
        let receipt = try await manager.captureMedia(projectName: "Project") {
            XCTAssertTrue(manager.hasActiveRequest)
            let asset = try manager.createAsset(name: "Project")
            XCTAssertTrue(asset.requiresMedia); XCTAssertTrue(asset.requestOwned)
            let xml = try self.write("Project.fcpxml", in: asset.directoryURL)
            let audio = try self.write("Project.wav", in: asset.directoryURL)
            XCTAssertTrue(manager.handleOpen(urls: [xml]))
            XCTAssertEqual(deliveries, 0)
            XCTAssertTrue(manager.handleOpen(urls: [audio]))
        }
        XCTAssertEqual(receipt.mediaURLs.count, 1)
        XCTAssertEqual(deliveries, 0)
        XCTAssertFalse(manager.hasActiveRequest)
        var pending: ShareDestinationAsset?
        do {
            _ = try await manager.captureMedia(projectName: "Canceled") {
                pending = try manager.createAsset(name: "Canceled")
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let asset = try XCTUnwrap(pending)
        let restored = ShareDestinationManager(rootURL: manager.rootURL)
        restored.onReceive = { _ in deliveries += 1 }
        let xml = try write("Canceled.fcpxml", in: asset.directoryURL)
        let audio = try write("Canceled.wav", in: asset.directoryURL)
        XCTAssertTrue(restored.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(try XCTUnwrap(restored.asset(id: asset.uniqueID)).requestOwned)
    }

    @MainActor func testMediaFilesWithoutCompletionDoNotCountAsFinishedRender() async throws {
        let manager = try manager()
        do {
            _ = try await manager.captureMedia(projectName: "Project", timeout: 0.05) {
                let asset = try manager.createAsset(name: "Project")
                _ = try self.write("Project.fcpxml", in: asset.directoryURL)
                _ = try self.write("Project.wav", in: asset.directoryURL)
            }
            XCTFail("Partial files cannot prove a completed render")
        } catch { XCTAssertFalse(manager.hasActiveRequest) }
    }

    @MainActor func testRequestsXMLAndMediaButNeverLibraryOrSourceCopy() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Audio Project", metadata: ["episodeID": "123"],
            dataOptions: ["availableDescriptionVersions": ["1.9", "1.10", "1.14"], "availableMetadataSets": ["None"]])
        XCTAssertEqual(asset.locationInfo["hasMedia"] as? Bool, true)
        XCTAssertEqual(asset.locationInfo["hasDescription"] as? Bool, true)
        XCTAssertEqual(asset.locationInfo["basename"] as? String, "Audio Project")
        XCTAssertEqual(asset.libraryInfo["hasArchive"] as? Bool, false)
        XCTAssertEqual(asset.libraryInfo["hasDescription"] as? Bool, false)
        XCTAssertEqual(asset.dataOptions["descriptionVersion"] as? String, "1.14")
        XCTAssertNil(asset.dataOptions["metadataSet"])
        XCTAssertEqual(asset.metadata["episodeID"] as? String, "123")
    }

    @MainActor func testPreservesHostDefaultForSymbolicDTDOptions() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project", dataOptions: ["availableDescriptionVersions": ["Current Version", "Previous Version"]])
        XCTAssertTrue(asset.dataOptions.count == 0)
    }

    @MainActor func testCompletedDeliveryUsesExactJobAndDescriptiveRoleSuffix() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        let audio = try write("Project-Dialogue.wav", in: asset.directoryURL)
        var receipt: ShareDestinationReceipt?
        manager.onReceive = { receipt = $0 }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(receipt?.id, asset.id)
        XCTAssertEqual(receipt?.xmlURL, xml)
        XCTAssertEqual(receipt?.mediaURLs, [audio])
        XCTAssertEqual(receipt?.mediaRoleSuffixes[audio], "Dialogue")
        XCTAssertNil(receipt?.metadata["renderedRoles"])
        var error: Error?
        manager.onFailure = { error = $0 }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(error as? ShareDestinationError, .alreadyCompleted)
    }

    @MainActor func testOpenEventsMayDeliverXMLAndMediaSeparately() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        let audio = try write("Project.aiff", in: asset.directoryURL)
        var receipts = 0
        manager.onReceive = { _ in receipts += 1 }
        XCTAssertTrue(manager.handleOpen(urls: [xml]))
        XCTAssertEqual(receipts, 0)
        XCTAssertTrue(manager.handleOpen(urls: [audio]))
        XCTAssertEqual(receipts, 1)
    }

    @MainActor func testRepeatedProjectNamesHaveSeparateExportOwnership() throws {
        let manager = try manager()
        let first = try manager.createAsset(name: "Project")
        let second = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: first.directoryURL)
        let audio = try write("Project.wav", in: second.directoryURL)
        var error: Error?
        manager.onFailure = { error = $0 }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(error as? ShareDestinationError, .unknownDelivery)
        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
    }

    @MainActor func testRejectsSymlinkEscapesAndUnexpectedFiles() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let external = try write("external.wav", in: manager.rootURL)
        let alias = asset.directoryURL.appendingPathComponent("Project.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
        XCTAssertThrowsError(try manager.receive(urls: [alias], for: asset))
        let wrongName = try write("Other.wav", in: asset.directoryURL)
        XCTAssertThrowsError(try manager.receive(urls: [wrongName], for: asset))
        let movie = try write("Project.mov", in: asset.directoryURL)
        XCTAssertThrowsError(try manager.receive(urls: [movie], for: asset)) { error in
            XCTAssertEqual(error as? ShareDestinationError, .unsupportedMedia)
        }
        let empty = try write("Project.caf", in: asset.directoryURL, contents: "")
        XCTAssertThrowsError(try manager.receive(urls: [empty], for: asset))
        XCTAssertFalse(manager.handleOpen(urls: [external]))
    }

    @MainActor func testBundleXMLAndDuplicateXMLValidation() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let package = asset.directoryURL.appendingPathComponent("Project.fcpxmld")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        _ = try write("Info.fcpxml", in: package)
        let audio = try write("Project.wav", in: asset.directoryURL)
        XCTAssertNotNil(try manager.receive(urls: [package, audio], for: asset))
        let extraXML = try write("Project.fcpxml", in: asset.directoryURL)
        XCTAssertThrowsError(try manager.receive(urls: [extraXML], for: asset)) { error in
            XCTAssertEqual(error as? ShareDestinationError, .duplicateXML)
        }
    }

    @MainActor func testPendingExportSurvivesHelperRestartWithoutTrustingPartialFiles() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        XCTAssertNil(try manager.receive(urls: [xml], for: asset))
        let restored = ShareDestinationManager(rootURL: manager.rootURL)
        let recovered = try XCTUnwrap(restored.asset(id: asset.uniqueID))
        XCTAssertEqual(recovered.name, asset.name)
        let audio = try write("Project.wav", in: asset.directoryURL)
        XCTAssertNil(try restored.receive(urls: [audio], for: recovered))
        XCTAssertNotNil(try restored.receive(urls: [xml, audio], for: recovered))
    }

    @MainActor func testUnsafeExportNamesCannotEscapeFolder() throws {
        let manager = try manager()
        for name in ["", " ", ".", "..", "../Elsewhere", "Volume:Folder", "\0", String(repeating: "a", count: 181)] {
            XCTAssertThrowsError(try manager.createAsset(name: name))
        }
        XCTAssertTrue(manager.assets.isEmpty)
    }

    @MainActor func testBusyReviewRejectsNewShareBeforeCreatingFiles() throws {
        let manager = try manager()
        manager.canBeginShare = { false }
        XCTAssertThrowsError(try manager.createAsset(name: "Project")) { error in
            XCTAssertEqual(error as? ShareDestinationError, .shareInProgress)
        }
        XCTAssertTrue(manager.assets.isEmpty)
    }

    @MainActor func testBusyCompletionRemainsAvailableForRetry() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        let audio = try write("Project.wav", in: asset.directoryURL)
        var count = 0
        manager.onReceive = { _ in count += 1 }
        manager.canBeginShare = { false }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(count, 0)
        manager.canBeginShare = { true }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        XCTAssertEqual(count, 1)
    }

    @MainActor func testCleanupRemovesOnlyCompletedRenderAndPreservesXMLAndSources() throws {
        let manager = try manager()
        let source = try write("Source.wav", in: manager.rootURL)
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        let audio = try write("Project.wav", in: asset.directoryURL)
        var receipt: ShareDestinationReceipt?
        manager.onReceive = { receipt = $0 }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        try manager.cleanupRenderedMedia(receipt: XCTUnwrap(receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: xml.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor func testCleanupPreservesReplacedRender() throws {
        let manager = try manager()
        let asset = try manager.createAsset(name: "Project")
        let xml = try write("Project.fcpxml", in: asset.directoryURL)
        let audio = try write("Project.wav", in: asset.directoryURL)
        var receipt: ShareDestinationReceipt?
        manager.onReceive = { receipt = $0 }
        XCTAssertTrue(manager.handleOpen(urls: [xml, audio]))
        try Data("User replaced this file".utf8).write(to: audio, options: .atomic)
        XCTAssertThrowsError(try manager.cleanupRenderedMedia(receipt: XCTUnwrap(receipt)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testUserRecordDescriptorPreservesListsBooleansAndUnicode() throws {
        let record: NSDictionary = ["availableDescriptionVersions": ["1.13", "1.14"],
            "enabled": true, "title": "Dialogue – 日本語", "metadata": ["episode": "42"]]
        let encoded = record.scriptingUserDefinedRecordDescriptor()
        let decoded = NSDictionary.scriptingUserDefinedRecord(with: encoded)
        XCTAssertEqual(decoded["availableDescriptionVersions"] as? [String], ["1.13", "1.14"])
        XCTAssertEqual(decoded["enabled"] as? Bool, true)
        XCTAssertEqual(decoded["title"] as? String, "Dialogue – 日本語")
        XCTAssertEqual((decoded["metadata"] as? [String: String])?["episode"], "42")
    }
}
