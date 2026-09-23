import AppKit
import Foundation
import CutdownCore

/// A completed custom Share delivery. Role suffixes are descriptive filename hints,
/// not proof that Final Cut exported a particular role mix.
public struct ShareDestinationReceipt {
    public let id: UUID
    public let name: String
    public let directoryURL: URL
    public let xmlURL: URL
    public let mediaURLs: [URL]
    public let metadata: [String: Any]
    public let dataOptions: [String: Any]
    public let mediaRoleSuffixes: [URL: String]

    public init(id: UUID, name: String, directoryURL: URL, xmlURL: URL,
                mediaURLs: [URL], metadata: [String: Any] = [:],
                dataOptions: [String: Any] = [:], mediaRoleSuffixes: [URL: String] = [:]) {
        self.id = id; self.name = name; self.directoryURL = directoryURL
        self.xmlURL = xmlURL; self.mediaURLs = mediaURLs
        self.metadata = metadata; self.dataOptions = dataOptions
        self.mediaRoleSuffixes = mediaRoleSuffixes
    }
}

public enum ShareDestinationError: LocalizedError, Equatable {
    case invalidName, invalidFile, unknownDelivery, duplicateXML, unsupportedMedia, alreadyCompleted, shareInProgress, changedDelivery, scriptingUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Final Cut supplied an empty or unsafe project name for Share to Cutdown."
        case .invalidFile: return "A shared file is missing, empty, or outside the folder reserved for this export. Share the project again."
        case .unknownDelivery: return "These files do not belong to a pending Share to Cutdown export."
        case .duplicateXML: return "Final Cut supplied more than one project XML file for this export."
        case .unsupportedMedia: return "Share to Cutdown needs uncompressed audio. Configure the destination for Audio Only with WAV, AIFF, or CAF audio."
        case .alreadyCompleted: return "This Share to Cutdown export was already received."
        case .shareInProgress: return "Another Share to Cutdown export or analysis is in progress. Wait for it to finish, or cancel it in Cutdown before sharing again."
        case .changedDelivery: return "A shared file changed after Final Cut delivered it. Cutdown left that file in place; share the project again."
        case .scriptingUnavailable: return "Cutdown could not create the scripting reference needed by Final Cut. Rebuild and register the helper with its Cutdown.sdef resource."
        }
    }
}

/// Cocoa Scripting handles make/get; the application delegate forwards open URLs.
/// No Final Cut Accessibility access, polling, or source-media copying is involved.
@MainActor public final class ShareDestinationManager {
    public static let shared = ShareDestinationManager()
    public var onReceive: ((ShareDestinationReceipt) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var canBeginShare: (() -> Bool)?
    public private(set) var assets: [ShareDestinationAsset] = []
    public let rootURL: URL

    private struct XMLRequest {
        let token: UUID
        let projectName: String
        var assetID: UUID?
        let requiresMedia: Bool
        var result: Result<ShareDestinationReceipt, Error>?
    }
    private var xmlRequest: XMLRequest?
    public var hasActiveRequest: Bool { xmlRequest != nil }

    /// The host initiates Share once; all destination and completion data then
    /// travels through Apple's Media Asset Protocol, with no rendered media.
    public func captureXML(projectName: String, timeout: TimeInterval = 30,
                           trigger: () async throws -> Void) async throws -> URL {
        return try await capture(projectName: projectName, requiresMedia: false, timeout: timeout, trigger: trigger).xmlURL
    }

    public func captureMedia(projectName: String, timeout: TimeInterval = 3600,
                             trigger: () async throws -> Void) async throws -> ShareDestinationReceipt {
        try await capture(projectName: projectName, requiresMedia: true, timeout: timeout, trigger: trigger)
    }

    private func capture(projectName: String, requiresMedia: Bool, timeout: TimeInterval,
                         trigger: () async throws -> Void) async throws -> ShareDestinationReceipt {
        guard xmlRequest == nil else { throw ShareDestinationError.shareInProgress }
        try Task.checkCancellation()
        let token = UUID()
        xmlRequest = XMLRequest(token: token, projectName: projectName, requiresMedia: requiresMedia)
        defer { if xmlRequest?.token == token { xmlRequest = nil } }
        try await trigger()
        let deadline = Date().addingTimeInterval(timeout)
        var delivery = StableXMLDelivery()
        while Date() < deadline {
            try Task.checkCancellation()
            if let result = xmlRequest?.result { return try result.get() }
            // Some host versions write XML but omit Open Document for XML-only
            // shares. Inspect only the exact fresh job's two permitted XML names.
            if let id = xmlRequest?.assetID, let asset = assets.first(where: { $0.id == id }), !asset.requiresMedia {
                let candidates = ["fcpxml", "fcpxmld"].map {
                    asset.directoryURL.appendingPathComponent(asset.name).appendingPathExtension($0)
                }.filter { FileManager.default.fileExists(atPath: $0.path) }
                if candidates.count > 1 { throw ShareDestinationError.duplicateXML }
                if let candidate = candidates.first {
                    let file = candidate.pathExtension == "fcpxmld" ? candidate.appendingPathComponent("Info.fcpxml") : candidate
                    if delivery.observe(try? Data(contentsOf: file), validate: {
                        (try? TimelineParser.parse(data: $0)) != nil
                    }) {
                        _ = handleOpen(urls: [candidate])
                        if let result = xmlRequest?.result { return try result.get() }
                    }
                } else {
                    delivery = StableXMLDelivery()
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FinalCutCaptureError.unavailable("Final Cut did not deliver the requested project XML through Share to Cutdown. No cuts were imported.")
    }

    public init(rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Cutdown/Share Inbox", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        restorePendingAssets()
    }

    @discardableResult public func createAsset(name: String, metadata: [String: Any] = [:],
                                               dataOptions: [String: Any] = [:]) throws -> ShareDestinationAsset {
        guard Self.isSafeBaseName(name) else { throw ShareDestinationError.invalidName }
        guard canBeginShare?() != false else { throw ShareDestinationError.shareInProgress }
        if let request = xmlRequest {
            guard request.assetID == nil, request.projectName == name else {
                throw ShareDestinationError.unknownDelivery
            }
        }
        let id = UUID()
        let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = ShareDestinationAsset(id: id, name: name, directoryURL: directory,
            metadata: metadata, offeredOptions: dataOptions, manager: self, requiresMedia: xmlRequest?.requiresMedia ?? true, requestOwned: xmlRequest != nil)
        assets.append(asset)
        if xmlRequest != nil { xmlRequest?.assetID = id }
        try persist(asset)
        record("make", asset: asset, details: ["offeredOptions": dataOptions])
        return asset
    }

    /// Returns false for an unrelated Open Document request. An owned delivery is
    /// matched by its unique job directory as well as its exact basename.
    @discardableResult public func handleOpen(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let candidates = assets.filter { asset in urls.contains { Self.isInside($0, directory: asset.directoryURL) } }
        guard !candidates.isEmpty else { return false }
        do {
            guard candidates.count == 1, let asset = candidates.first,
                  urls.allSatisfy({ Self.isInside($0, directory: asset.directoryURL) }) else {
                throw ShareDestinationError.unknownDelivery
            }
            if asset.completed && !asset.requiresMedia {
                guard Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }) == asset.receivedURLs,
                      let xml = asset.receivedURLs.first else { throw ShareDestinationError.changedDelivery }
                try validateReceipt(ShareDestinationReceipt(id: asset.id, name: asset.name,
                    directoryURL: asset.directoryURL, xmlURL: xml, mediaURLs: []))
                return true // Late Open Document after validated file readiness.
            }
            guard !asset.completed else { throw ShareDestinationError.alreadyCompleted }
            guard canBeginShare?() != false else { throw ShareDestinationError.shareInProgress }
            let receipt = try receive(urls: urls, for: asset)
            if let receipt {
                asset.completed = true
                try persist(asset)
                record("open-complete", asset: asset, details: ["files": urls.map(\.path)])
                if asset.requestOwned || !asset.requiresMedia {
                    if xmlRequest?.assetID == asset.id { xmlRequest?.result = .success(receipt) }
                    // A canceled or restarted request must never start a different analysis.
                } else { onReceive?(receipt) }
            } else {
                record("open-partial", asset: asset, details: ["files": urls.map(\.path)])
            }
        } catch {
            record("open-failed", asset: candidates.first, details: ["error": error.localizedDescription])
            if let candidate = candidates.first, xmlRequest?.assetID == candidate.id {
                xmlRequest?.result = .failure(error)
            } else { onFailure?(error) }
        }
        return true
    }

    public func asset(id: String) -> ShareDestinationAsset? { assets.first { $0.uniqueID == id } }

    /// Validates only files named by Final Cut's completion event; never discovers
    /// media by scanning a directory or guesses which export was most recent.
    public func receive(urls: [URL], for asset: ShareDestinationAsset) throws -> ShareDestinationReceipt? {
        guard assets.contains(where: { $0 === asset }) else { throw ShareDestinationError.unknownDelivery }
        var received = asset.receivedURLs
        var identities = asset.fileIdentities
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL, url.standardizedFileURL == canonical,
                  canonical.deletingLastPathComponent().path == asset.directoryURL.path else {
                throw ShareDestinationError.invalidFile
            }
            let ext = canonical.pathExtension.lowercased()
            let base = canonical.deletingPathExtension().lastPathComponent
            let isXML = ext == "fcpxml" || ext == "fcpxmld"
            guard isXML ? base == asset.name : (base == asset.name || base.hasPrefix(asset.name + "-")) else {
                throw ShareDestinationError.invalidFile
            }
            guard isXML || (asset.requiresMedia && ["wav", "aif", "aiff", "caf"].contains(ext)) else {
                throw ShareDestinationError.unsupportedMedia
            }
            let file = ext == "fcpxmld" ? canonical.appendingPathComponent("Info.fcpxml") : canonical
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard file.resolvingSymlinksInPath() == file, values.isRegularFile == true,
                  values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw ShareDestinationError.invalidFile
            }
            let identity = try ShareDestinationFileIdentity(file: file)
            if let previous = identities[canonical], previous != identity { throw ShareDestinationError.changedDelivery }
            identities[canonical] = identity
            received.insert(canonical)
        }
        let xml = received.filter { ["fcpxml", "fcpxmld"].contains($0.pathExtension.lowercased()) }
        guard xml.count <= 1 else { throw ShareDestinationError.duplicateXML }
        let media = received.subtracting(xml).sorted { $0.path < $1.path }
        asset.receivedURLs = received
        asset.fileIdentities = identities
        try persist(asset)
        guard let xmlURL = xml.first, !asset.requiresMedia || !media.isEmpty else { return nil }
        let suffixes = Dictionary(uniqueKeysWithValues: media.compactMap { url -> (URL, String)? in
            let base = url.deletingPathExtension().lastPathComponent
            guard base.hasPrefix(asset.name + "-") else { return nil }
            return (url, String(base.dropFirst(asset.name.count + 1)))
        })
        return ShareDestinationReceipt(id: asset.id, name: asset.name,
            directoryURL: asset.directoryURL, xmlURL: xmlURL, mediaURLs: media,
            metadata: asset.metadata as? [String: Any] ?? [:],
            dataOptions: asset.dataOptions as? [String: Any] ?? [:], mediaRoleSuffixes: suffixes)
    }

    /// Recheck the delivered XML and PCM identities after decoding before a
    /// consumer accepts the analysis. This does not read or modify Final Cut.
    public func validateReceipt(_ receipt: ShareDestinationReceipt) throws {
        guard let asset = asset(id: receipt.id.uuidString), asset.completed,
              asset.directoryURL.path == receipt.directoryURL.path, asset.name == receipt.name,
              Set(receipt.mediaURLs + [receipt.xmlURL]) == asset.receivedURLs else {
            throw ShareDestinationError.unknownDelivery
        }
        for url in asset.receivedURLs {
            let file = url.pathExtension.lowercased() == "fcpxmld" ? url.appendingPathComponent("Info.fcpxml") : url
            guard url.deletingLastPathComponent().path == asset.directoryURL.path,
                  let identity = asset.fileIdentities[url],
                  try ShareDestinationFileIdentity(file: file) == identity else {
                throw ShareDestinationError.changedDelivery
            }
        }
    }

    /// Remove only completed, unchanged PCM render files from this job. Retain
    /// the small project XML and event evidence. Never recurse into media folders.
    public func cleanupRenderedMedia(receipt: ShareDestinationReceipt) throws {
        // Validate every file before deleting any file. An edited or replaced
        // artifact remains available to the user, even at an owned filename.
        try validateReceipt(receipt)
        for url in receipt.mediaURLs { try FileManager.default.removeItem(at: url) }
        record("render-cleanup", asset: asset(id: receipt.id.uuidString),
               details: ["files": receipt.mediaURLs.map(\.lastPathComponent)])
    }

    static func isSafeBaseName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains(":") && !name.contains("\0")
            && name.utf8.count <= 180
    }

    private static func isInside(_ url: URL, directory: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.path + "/")
    }

    func record(_ event: String, asset: ShareDestinationAsset?, details: [String: Any] = [:]) {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var record = details
        record["event"] = event
        record["date"] = ISO8601DateFormatter().string(from: Date())
        record["jobID"] = asset?.uniqueID
        record["name"] = asset?.name
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let file = rootURL.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func persist(_ asset: ShareDestinationAsset) throws {
        let dictionary: [String: Any] = ["version": 1, "id": asset.uniqueID, "name": asset.name,
            "metadata": asset.metadata, "offeredOptions": asset.offeredOptions,
            "receivedFiles": asset.receivedURLs.map(\.lastPathComponent), "completed": asset.completed,
            "requiresMedia": asset.requiresMedia, "requestOwned": asset.requestOwned]
        guard JSONSerialization.isValidJSONObject(dictionary) else { return }
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: asset.directoryURL.appendingPathComponent("cutdown-share-job.json"), options: .atomic)
    }

    private func restorePendingAssets() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: rootURL,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("cutdown-share-job.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["version"] as? Int == 1, let idText = json["id"] as? String,
                  idText == folder.lastPathComponent, let id = UUID(uuidString: idText),
                  let name = json["name"] as? String, Self.isSafeBaseName(name),
                  json["completed"] as? Bool == false else { continue }
            let asset = ShareDestinationAsset(id: id, name: name, directoryURL: rootURL.appendingPathComponent(id.uuidString, isDirectory: true),
                metadata: json["metadata"] as? [String: Any] ?? [:],
                offeredOptions: json["offeredOptions"] as? [String: Any] ?? [:], manager: self,
                requiresMedia: json["requiresMedia"] as? Bool ?? true,
                requestOwned: json["requestOwned"] as? Bool ?? false)
            // Completion must be delivered again after a restart; don't trust old
            // file names from an interrupted Open Document event as current input.
            assets.append(asset)
        }
    }
}

@objc(CutdownShareAsset) @MainActor public final class ShareDestinationAsset: NSObject {
    public let id: UUID
    @objc public dynamic var uniqueID: String { id.uuidString }
    @objc public dynamic var name: String
    public let directoryURL: URL
    @objc public dynamic var metadata: NSDictionary
    @objc public dynamic var dataOptions: NSDictionary
    public let offeredOptions: [String: Any]
    public let requiresMedia: Bool
    public let requestOwned: Bool
    fileprivate var receivedURLs = Set<URL>()
    fileprivate var completed = false
    fileprivate var fileIdentities: [URL: ShareDestinationFileIdentity] = [:]
    private weak var manager: ShareDestinationManager?

    init(id: UUID, name: String, directoryURL: URL, metadata: [String: Any],
         offeredOptions: [String: Any], manager: ShareDestinationManager, requiresMedia: Bool = true, requestOwned: Bool = false) {
        self.requestOwned = requestOwned
        self.requiresMedia = requiresMedia
        self.id = id; self.name = name; self.directoryURL = directoryURL
        self.metadata = metadata as NSDictionary
        self.offeredOptions = offeredOptions
        // Choose only a numeric version actually advertised by Final Cut. Its
        // documented symbolic labels remain available as the host default.
        let versions = offeredOptions["availableDescriptionVersions"] as? [String] ?? []
        let numeric = versions.filter { $0.range(of: "^[0-9]+(\\.[0-9]+)+$", options: .regularExpression) != nil }
        let version = numeric.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
        self.dataOptions = version.map { ["descriptionVersion": $0] as NSDictionary } ?? [:]
        self.manager = manager
        super.init()
    }

    @objc public dynamic var locationInfo: NSDictionary {
        manager?.record("get-location", asset: self)
        return ["folder": directoryURL as NSURL, "basename": name, "hasMedia": requiresMedia, "hasDescription": true]
    }
    @objc public dynamic var libraryInfo: NSDictionary {
        manager?.record("get-library", asset: self)
        return ["hasArchive": false, "hasDescription": false]
    }
    public override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let description = NSApplication.shared.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description,
            containerSpecifier: nil, key: "cutdownShareAssets", uniqueID: uniqueID)
    }
}

extension NSApplication {
    @objc public var cutdownShareAssets: [ShareDestinationAsset] { ShareDestinationManager.shared.assets }
    @objc(valueInCutdownShareAssetsWithUniqueID:)
    public func cutdownShareAsset(withUniqueID id: String) -> ShareDestinationAsset? {
        ShareDestinationManager.shared.asset(id: id)
    }
}

@objc(CutdownShareMakeCommand) public final class ShareDestinationMakeCommand: NSCreateCommand {
    public override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do {
                guard createClassDescription.className == "CutdownShareAsset" || createClassDescription.appleEventCode == 0x61736574 else {
                    throw ShareDestinationError.unknownDelivery
                }
                let properties = resolvedKeyDictionary
                guard let name = properties["name"] as? String else { throw ShareDestinationError.invalidName }
                // The handler never opens UI, including when kAENeverInteract is
                // present. Final Cut remains responsible for its export UI.
                let manager = ShareDestinationManager.shared
                let asset = try manager.createAsset(name: name,
                    metadata: properties["metadata"] as? [String: Any] ?? [:],
                    dataOptions: properties["dataOptions"] as? [String: Any] ?? [:])
                // The sdef result is a specifier. Returning the NSObject itself
                // triggers a Cocoa scripting conversion exception before Final
                // Cut can ask for location info; return its reference explicitly.
                guard let specifier = asset.objectSpecifier else { throw ShareDestinationError.scriptingUnavailable }
                manager.record("make-reference", asset: asset,
                    details: ["reference": String(describing: specifier)])
                return specifier
            } catch {
                scriptErrorNumber = -1708
                scriptErrorString = error.localizedDescription
                ShareDestinationManager.shared.onFailure?(error)
                return nil
            }
        }
    }
}

/// Device/inode, length, and timestamps detect replacement or modification before
/// removing a completed temporary render, without rereading large PCM files.
fileprivate struct ShareDestinationFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let created: Date

    init(file: URL) throws {
        guard file.isFileURL, file.standardizedFileURL.resolvingSymlinksInPath() == file else {
            throw ShareDestinationError.invalidFile
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date else { throw ShareDestinationError.invalidFile }
        self.device = device.uint64Value; self.inode = inode.uint64Value; self.size = size.uint64Value
        self.modified = modified; self.created = created
    }
}
