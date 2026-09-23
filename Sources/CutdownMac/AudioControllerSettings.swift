import CutdownCore
import CoreFoundation
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads the exact clip occurrence's native Audio Inspector controls. Final Cut
/// can export a newer scalar value than the AU instance's archived state; explicit
/// exported values therefore take precedence over the verified saved state.
public enum AudioControllerSettings {
    static func equivalent(_ lhs: AnalysisSettings, _ rhs: AnalysisSettings) -> Bool {
        Float(lhs.thresholdDBFS) == Float(rhs.thresholdDBFS)
            && Float(lhs.minimumSilenceDuration) == Float(rhs.minimumSilenceDuration)
            && Float(lhs.beforeSpeechPadding) == Float(rhs.beforeSpeechPadding)
            && Float(lhs.afterSpeechPadding) == Float(rhs.afterSpeechPadding)
    }
    /// Verified in a native FCP 12.3 export of our aufx/ctdn/Ctdn component.
    public static let effectUID = "AudioUnit: 0x617566786374646e4374646e"

    /// Encode the submitted values, not a possibly empty/stale host snapshot.
    /// Uses the same bounded native AU state format accepted by the reader and
    /// the plug-in's private parameter codec. Does not instantiate an Audio Unit.
    static func embedding(_ settings: AnalysisSettings, in data: Data, selection: TimelineSelection) throws -> Data {
        let document = try TimelineParser.parse(data: data)
        let target = try document.selectedTarget(selection, requireExistingMedia: false)
        try validateInteractive(projectData: data, target: target, requested: settings)
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let resources = try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
        let ids = Set(resources.filter { $0.attribute(forName: "uid")?.stringValue == effectUID }
            .compactMap { $0.attribute(forName: "id")?.stringValue })
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first,
              let index = Int(target.id.split(separator: "/").last ?? ""),
              elements(in: spine).indices.contains(index),
              let controller = elements(in: spine)[index].elements(forName: "filter-audio").first(where: {
                  ids.contains($0.attribute(forName: "ref")?.stringValue ?? "")
              }) else { throw AudioControllerSettingsError.missingController }
        var packet = stateSkeleton
        for (parameter, offset) in zip(parameters, stateOffsets) {
            let bits = Float(settings[keyPath: parameter.value]).bitPattern
            packet.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        let state: NSDictionary = ["manufacturer": 0x4374646e, "type": 0x61756678,
            "subtype": 0x6374646e, "version": 1, "data": packet]
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(state, forKey: "effectState")
        encoder.finishEncoding()
        let payload = XMLElement(name: "data", stringValue: encoder.encodedData.base64EncodedString())
        payload.addAttribute(XMLNode.attribute(withName: "key", stringValue: "effectState") as! XMLNode)
        controller.setChildren([payload])
        // A stale preset reference must not override the explicit submitted state.
        controller.removeAttribute(forName: "presetID")
        for parameter in parameters {
            let node = XMLElement(name: "param")
            for (key, value) in [("key", parameter.key), ("name", parameter.name),
                                 ("value", String(settings[keyPath: parameter.value]))] {
                node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
            }
            controller.addChild(node)
        }
        let result = xml.xmlData
        try validate(projectData: result, target: target, requested: settings)
        return result
    }

    private static let stateOffsets = [26, 50, 72, 94]
    private static let stateSkeleton = Data(base64Encoded: "AAAAAAkAAAB0AGgAcgBlAHMAaABvAGwAZAAAAAAAAAAHAAAAbQBpAG4AaQBtAHUAbQAAAAAAAAAGAAAAYgBlAGYAbwByAGUAAAAAAAAAAAAFAAAAYQBmAHQAZQByAAAAAAD/")!

    private struct Parameter {
        let key: String
        let name: String
        let range: ClosedRange<Double>
        let value: KeyPath<AnalysisSettings, Double>
    }
    private static let parameters = [
        Parameter(key: "4037165010", name: "Silence Threshold", range: -80...0, value: \.thresholdDBFS),
        // Match the Audio Unit's Float32 minimum so its exported boundary value survives validation.
        Parameter(key: "3342540801", name: "Minimum Silence", range: Double(Float(0.0001))...10, value: \.minimumSilenceDuration),
        Parameter(key: "4090893112", name: "Before Speech", range: 0...2, value: \.beforeSpeechPadding),
        Parameter(key: "252981911", name: "After Speech", range: 0...2, value: \.afterSpeechPadding)
    ]

    /// A Share to Cutdown job obtains settings from the effect already saved in
    /// the project. No helper-window defaults or a running AU instance are used.
    public static func read(projectData: Data, target: TimelineClip) throws -> AnalysisSettings {
        guard let settings = try readIfPresent(projectData: projectData, target: target) else {
            throw AudioControllerSettingsError.missingController
        }
        return settings
    }

    public static func read(projectXML: URL, target: TimelineClip) throws -> AnalysisSettings {
        let url = projectXML.pathExtension.lowercased() == "fcpxmld"
            ? projectXML.appendingPathComponent("Info.fcpxml") : projectXML
        return try read(projectData: Data(contentsOf: url), target: target)
    }

    /// Interactive analysis requires the known Cutdown AU on the exact target.
    /// Read-only verification may explicitly allow an absent controller; if an
    /// AU is present, every identity and settings check is still mandatory.
    @discardableResult public static func validate(
        projectXML: URL, target: TimelineClip, requested: AnalysisSettings, requireController: Bool = true, allowOmittedPrivateSettings: Bool = false
    ) throws -> Bool {
        let url = projectXML.pathExtension.lowercased() == "fcpxmld"
            ? projectXML.appendingPathComponent("Info.fcpxml") : projectXML
        return try validate(projectData: Data(contentsOf: url), target: target, requested: requested,
                            requireController: requireController, allowOmittedPrivateSettings: allowOmittedPrivateSettings)
    }

    @discardableResult public static func validate(
        projectData: Data, target: TimelineClip, requested: AnalysisSettings, requireController: Bool = true, allowOmittedPrivateSettings: Bool = false
    ) throws -> Bool {
        guard let exported = try readIfPresent(projectData: projectData, target: target,
            submittedPrivateSettings: allowOmittedPrivateSettings ? requested : nil) else {
            if requireController || allowOmittedPrivateSettings { throw AudioControllerSettingsError.missingController }
            return false
        }
        var mismatched: [String] = []
        for expected in parameters {
            let requestedValue = requested[keyPath: expected.value]
            guard requestedValue.isFinite, expected.range.contains(requestedValue) else {
                throw AudioControllerSettingsError.invalidParameter(expected.name)
            }
            // AUValue is Float32. Compare at that exact precision so decimal XML
            // and NSNumber descriptions round to the same representable value.
            if Float(exported[keyPath: expected.value]) != Float(requestedValue) {
                mismatched.append(expected.name)
            }
        }
        guard mismatched.isEmpty else { throw AudioControllerSettingsError.settingsMismatch(mismatched) }
        return true
    }

    /// The explicit window request owns detection settings. Host XML establishes
    /// controller identity and validates any serialized state, but delayed host
    /// persistence must not override a setting the user just submitted.
    static func validateInteractive(projectData: Data, target: TimelineClip, requested: AnalysisSettings) throws {
        guard try readIfPresent(projectData: projectData, target: target, submittedPrivateSettings: requested) != nil else {
            throw AudioControllerSettingsError.missingController
        }
        for parameter in parameters {
            let value = requested[keyPath: parameter.value]
            guard value.isFinite, parameter.range.contains(value) else {
                throw AudioControllerSettingsError.invalidParameter(parameter.name)
            }
        }
    }

    /// Apply occurs after the host has had time to save the submitted controls.
    /// Reject any newly exported values that differ from the analyzed settings.
    /// A bare controller still uses the explicit request because it exports no
    /// private values to compare.
    static func validateForApply(projectData: Data, target: TimelineClip, requested: AnalysisSettings) throws {
        try validate(projectData: projectData, target: target, requested: requested,
            allowOmittedPrivateSettings: true)
    }

    /// nil means only that the verified target has no known Cutdown controller.
    /// A present but invalid, duplicate or disabled controller always throws.
    private static func readIfPresent(projectData: Data, target: TimelineClip, submittedPrivateSettings: AnalysisSettings? = nil) throws -> AnalysisSettings? {
        // Reuse the core parser's size, DTD, entity, nesting and timeline checks
        // before inspecting XML elements. Both reads consume the same Data value.
        let document = try TimelineParser.parse(data: projectData)
        let current = try document.selectedTarget(.init(timelineRange: target.timelineRange,
            sourceURL: target.mediaURL, sourceStart: target.sourceStart), requireExistingMedia: false)
        guard current.id == target.id, current.assetID == target.assetID,
              current.assetStart == target.assetStart, current.kind == "asset-clip",
              current.parentID == nil, target.isPrimaryStoryline else {
            throw AudioControllerSettingsError.targetChanged
        }
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let projects = try xml.nodes(forXPath: "//project").compactMap { $0 as? XMLElement }
        guard projects.count == 1, projects[0].elements(forName: "sequence").count == 1,
              let sequence = projects[0].elements(forName: "sequence").first,
              sequence.elements(forName: "spine").count == 1,
              let spine = sequence.elements(forName: "spine").first else {
            throw AudioControllerSettingsError.targetChanged
        }
        let path = current.id.split(separator: "/", omittingEmptySubsequences: false)
        let items = elements(in: spine)
        guard path.count == 2, path[0] == "spine", let index = Int(path[1]),
              String(index) == path[1], items.indices.contains(index), items[index].name == "asset-clip" else {
            throw AudioControllerSettingsError.targetChanged
        }
        guard let root = xml.rootElement(), root.elements(forName: "resources").count == 1,
              let resources = root.elements(forName: "resources").first else {
            throw AudioControllerSettingsError.targetChanged
        }
        let effectIDs = Set(resources.elements(forName: "effect").filter {
            $0.attribute(forName: "uid")?.stringValue == effectUID
        }.compactMap { $0.attribute(forName: "id")?.stringValue })
        let clip = items[index]
        let matches = try clip.nodes(forXPath: ".//filter-audio").compactMap { $0 as? XMLElement }.filter {
            guard let ref = $0.attribute(forName: "ref")?.stringValue, effectIDs.contains(ref) else { return false }
            // A connected/nested clip's own controller does not belong to target.
            var ancestor = $0.parent
            while let node = ancestor, node !== clip {
                if let name = node.name, ["asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "spine", "audition"].contains(name) { return false }
                ancestor = node.parent
            }
            return ancestor === clip
        }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else { throw AudioControllerSettingsError.ambiguousController }
        let effect = matches[0]
        guard effect.parent === clip else { throw AudioControllerSettingsError.unsupportedControllerLocation }
        guard effect.attribute(forName: "enabled")?.stringValue != "0" else {
            throw AudioControllerSettingsError.disabledController
        }
        return try readValues(in: effect, submittedPrivateSettings: submittedPrivateSettings)
    }

    /// Parse each document once for import reporting, rather than reparsing the
    /// whole project for every retained segment (which can number in thousands).
    static func settingsByPrimaryClip(projectData: Data) throws -> [String: AnalysisSettings] {
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let ids = Set(try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
            .filter { $0.attribute(forName: "uid")?.stringValue == effectUID }
            .compactMap { $0.attribute(forName: "id")?.stringValue })
        guard let spine = try xml.nodes(forXPath: "//project/sequence/spine").first else { return [:] }
        var settings: [String: AnalysisSettings] = [:]
        for (index, clip) in elements(in: spine).enumerated() where clip.name == "asset-clip" {
            let matches = clip.elements(forName: "filter-audio").filter { ids.contains($0.attribute(forName: "ref")?.stringValue ?? "") }
            if matches.count == 1, matches[0].attribute(forName: "enabled")?.stringValue != "0",
               let value = try? readValues(in: matches[0]) { settings["spine/\(index)"] = value }
        }
        return settings
    }

    private static func readValues(in effect: XMLElement, submittedPrivateSettings: AnalysisSettings? = nil) throws -> AnalysisSettings {
        // Current window-only AU instances can export a bare filter reference.
        // Only an explicit interactive request may supply its private settings.
        // Never use defaults, or rescue partial/malformed/unknown exported state.
        if let submittedPrivateSettings, elements(in: effect).isEmpty,
           (effect.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Set((effect.attributes ?? []).compactMap(\.name)).isSubset(of: ["ref", "name", "enabled", "presetID"]) {
            return submittedPrivateSettings
        }
        let controls = effect.elements(forName: "param")
        guard controls.count <= parameters.count else { throw AudioControllerSettingsError.unavailableSettings }
        guard elements(in: effect).allSatisfy({ ["param", "data"].contains($0.name ?? "") }) else {
            throw AudioControllerSettingsError.unavailableSettings
        }
        guard controls.allSatisfy({ control in
            parameters.contains { $0.key == control.attribute(forName: "key")?.stringValue }
        }) else { throw AudioControllerSettingsError.invalidParameter("Unknown control") }
        var exportedValues: [String: Double] = [:]
        for expected in parameters {
            let matching = controls.filter { $0.attribute(forName: "key")?.stringValue == expected.key }
            guard matching.count <= 1 else { throw AudioControllerSettingsError.invalidParameter(expected.name) }
            guard !matching.isEmpty else { continue }
            let control = matching[0]
            guard control.attribute(forName: "name")?.stringValue == expected.name,
                  Set((control.attributes ?? []).compactMap(\.name)) == ["name", "key", "value"],
                  elements(in: control).isEmpty,
                  (control.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let text = control.attribute(forName: "value")?.stringValue,
                  let exported = Double(text), exported.isFinite, expected.range.contains(exported) else {
                throw AudioControllerSettingsError.invalidParameter(expected.name)
            }
            exportedValues[expected.key] = exported
        }
        if exportedValues.count < parameters.count {
            // FCP omits unchanged scalars, including values inherited from the
            // AU's last-used settings. Recover them only from this instance's
            // verified saved state. Explicit scalars take precedence because
            // FCP can update those before updating the archived AU state.
            let saved = try archivedValues(in: effect)
            for (index, parameter) in parameters.enumerated() where exportedValues[parameter.key] == nil {
                exportedValues[parameter.key] = saved[index]
            }
        }
        let values = try parameters.map { parameter -> Double in
            guard let value = exportedValues[parameter.key] else { throw AudioControllerSettingsError.unavailableSettings }
            return value
        }
        return try AnalysisSettings(thresholdDBFS: values[0], minimumSilenceDuration: values[1],
            beforeSpeechPadding: values[2], afterSpeechPadding: values[3])
    }

    /// The known FCP 12.3 archive wraps AUAudioUnit's parameter-tree state. Never
    /// restore an AU or instantiate application classes while inspecting it.
    /// Unknown archive/packet versions fail closed instead of using defaults.
    private static func archivedValues(in effect: XMLElement) throws -> [Double] {
        let states = effect.elements(forName: "data").filter { $0.attribute(forName: "key")?.stringValue == "effectState" }
        guard states.count == 1, let state = states.first,
              Set((state.attributes ?? []).compactMap(\.name)) == ["key"],
              elements(in: state).isEmpty, let text = state.stringValue,
              text.utf8.count <= 16_384,
              let data = Data(base64Encoded: text.components(separatedBy: .whitespacesAndNewlines).joined()),
              data.count <= 12_288, data.starts(with: Data("bplist00".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              Set(plist.keys) == ["$archiver", "$version", "$top", "$objects"],
              plist["$archiver"] as? String == "NSKeyedArchiver",
              let archiveVersion = plist["$version"] as? NSNumber, integer(archiveVersion, equals: 100_000),
              let top = plist["$top"] as? [String: Any], Set(top.keys) == ["effectState"],
              let objects = plist["$objects"] as? [Any], objects.count <= 32 else {
            throw AudioControllerSettingsError.unavailableSettings
        }
        // The sole archived class must be Foundation's inert dictionary. The
        // property list is bounded before the secure decoder sees any objects.
        let classes = objects.compactMap { $0 as? [String: Any] }.filter { $0["$classname"] != nil }
        guard classes.count == 1, let descriptor = classes.first,
              Set(descriptor.keys) == ["$classname", "$classes"],
              (descriptor["$classname"] as? String == "NSMutableDictionary" &&
                descriptor["$classes"] as? [String] == ["NSMutableDictionary", "NSDictionary", "NSObject"] ||
               descriptor["$classname"] as? String == "NSDictionary" &&
                descriptor["$classes"] as? [String] == ["NSDictionary", "NSObject"]) else {
            throw AudioControllerSettingsError.unavailableSettings
        }
        let decoder: NSKeyedUnarchiver
        do { decoder = try NSKeyedUnarchiver(forReadingFrom: data) }
        catch { throw AudioControllerSettingsError.unavailableSettings }
        decoder.requiresSecureCoding = true
        decoder.decodingFailurePolicy = .setErrorAndReturn
        let decoded = decoder.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self, NSData.self],
                                           forKey: "effectState") as? [String: Any]
        decoder.finishDecoding()
        guard decoder.error == nil, let decoded,
              Set(decoded.keys) == ["manufacturer", "type", "subtype", "version", "data"],
              let manufacturer = decoded["manufacturer"] as? NSNumber, integer(manufacturer, equals: 0x4374646e),
              let type = decoded["type"] as? NSNumber, integer(type, equals: 0x61756678),
              let subtype = decoded["subtype"] as? NSNumber, integer(subtype, equals: 0x6374646e),
              let version = decoded["version"] as? NSNumber, integer(version, equals: 1),
              let packet = decoded["data"] as? Data else {
            throw AudioControllerSettingsError.unavailableSettings
        }
        // Verified native arm64 AUAudioUnit state: fixed identifiers threshold,
        // minimum, before, after, and four little-endian Float32 value slots.
        // Match every other byte; a future serialization format is unsupported.
        let skeleton = stateSkeleton
        guard packet.count == skeleton.count else { throw AudioControllerSettingsError.unavailableSettings }
        let offsets = stateOffsets
        var normalized = packet
        var result: [Double] = []
        for (index, offset) in offsets.enumerated() {
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(packet[offset + $1]) << ($1 * 8) }
            let value = Double(Float(bitPattern: bits))
            guard value.isFinite, parameters[index].range.contains(value) else {
                throw AudioControllerSettingsError.invalidParameter(parameters[index].name)
            }
            result.append(value)
            normalized.replaceSubrange(offset..<(offset + 4), with: [UInt8](repeating: 0, count: 4))
        }
        guard normalized == skeleton else { throw AudioControllerSettingsError.unavailableSettings }
        return result
    }

    private static func integer(_ number: NSNumber, equals expected: UInt32) -> Bool {
        CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue == Double(expected)
    }

    private static func elements(in node: XMLNode) -> [XMLElement] {
        (node.children ?? []).compactMap { $0 as? XMLElement }
    }
}

public enum AudioControllerSettingsError: LocalizedError, Equatable {
    case targetChanged, missingController, ambiguousController, disabledController, unsupportedControllerLocation, unavailableSettings
    case invalidParameter(String)
    case settingsMismatch([String])

    public var errorDescription: String? {
        switch self {
        case .targetChanged:
            return "The selected audio-only clip changed. Select the exact clip and Analyze Again."
        case .missingController:
            return "The selected audio-only clip does not carry Cutdown Audio. Select the clip with this effect, or apply Cutdown Audio to it, then Analyze Again."
        case .ambiguousController:
            return "Multiple Cutdown Audio effects on this clip. Remove the extra one in the Audio Inspector, then Analyze Again."
        case .disabledController:
            return "The selected Cutdown Audio effect is disabled. Enable it and Analyze Again."
        case .unsupportedControllerLocation:
            return "Cutdown Audio must be applied directly to the selected audio-only clip. Component-level effects are not supported yet."
        case .unavailableSettings:
            return "Final Cut did not export a complete, supported set of saved Cutdown Audio controls. Finish updating all four controls, then Analyze Again."
        case .invalidParameter(let name):
            return "Final Cut exported an ambiguous, animated or invalid Cutdown Audio control: \(name). Restore a fixed value and Analyze Again."
        case .settingsMismatch(let names):
            return "Final Cut's current controls differ from the Analyze request: \(names.joined(separator: ", ")). Finish updating the effect, then Analyze Again."
        }
    }
}
