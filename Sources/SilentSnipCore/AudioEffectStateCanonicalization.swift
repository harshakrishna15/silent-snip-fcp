import Foundation
import CoreFoundation

/// Comparison only. Never unarchives objects, changes import XML, interprets
/// an AU's opaque data, or treats a recognized archive as complete native state.
/// Final Cut may reorder an inert effectState NSDictionary on native transfer.
enum AudioEffectStateCanonicalization {
    private static let uidMarker = "__SilentSnipComparisonUID_v1"

    static func canonical(_ base64: String) -> String? {
        guard base64.utf8.count <= 1_500_000,
              let bytes = Data(base64Encoded: base64.components(separatedBy: .whitespacesAndNewlines).joined()),
              bytes.count <= 1_048_576, bytes.starts(with: Data("bplist00".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              referencesAreUIDAtoms(plist),
              // Convert UID atoms to the public XML-plist CF$UID representation.
              // No NSKeyedUnarchiver or application class is instantiated.
              let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              let xmlText = String(data: xml, encoding: .utf8),
              // The plist reader restores CF$UID dictionaries to UID atoms.
              // Rename only generated XML key tags to keep these references
              // inert and inspectable through public dictionary APIs.
              let inspectable = xmlText.replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>\(uidMarker)</key>").data(using: .utf8),
              let archive = try? PropertyListSerialization.propertyList(from: inspectable, options: [], format: nil) as? [String: Any],
              Set(archive.keys) == ["$archiver", "$version", "$top", "$objects"],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let version = archive["$version"] as? NSNumber,
              integer(version) == "100000",
              let top = archive["$top"] as? [String: Any], Set(top.keys) == ["effectState"],
              let objects = archive["$objects"] as? [Any], (2...4_096).contains(objects.count),
              let originalObjects = plist["$objects"] as? [Any], originalObjects.count == objects.count,
              objects[0] as? String == "$null" else { return nil }
        // XML is only a bridge for UID references. Keep scalar objects from
        // the original binary plist, including exact real/date bit patterns.
        let preserved = objects.indices.map { index -> Any in
            let original = originalObjects[index]
            if original is String || original is Data || original is NSNumber || original is Date { return original }
            return objects[index]
        }
        var decoder = Decoder(objects: preserved)
        guard let root = try? decoder.resolve(top["effectState"]!, depth: 0, path: []),
              case .dictionary(let entries) = root,
              decoder.seen.union([0]).count == objects.count else { return nil }
        // Recognize AU state rather than arbitrary keyed dictionaries. Preserve
        // every additional key/value and every opaque data byte in canonical().
        for key in ["manufacturer", "type", "subtype", "version"] {
            guard let value = entries.first(where: { $0.0 == key })?.1,
                  case .integer = value else { return nil }
        }
        guard let data = entries.first(where: { $0.0 == "data" })?.1,
              case .data = data else { return nil }
        return "semantic-au-state-v1:" + root.canonical
    }

    private static func integer(_ number: NSNumber) -> String? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard !["f", "d"].contains(type) else { return nil }
        return number.stringValue
    }

    private static func referencesAreUIDAtoms(_ archive: [String: Any]) -> Bool {
        // XML represents both a real binary UID and an ordinary dictionary
        // containing CF$UID identically. Reject the latter before conversion.
        guard let top = archive["$top"] as? [String: Any],
              let root = top["effectState"], !(root is NSDictionary),
              let objects = archive["$objects"] as? [Any], objects.count <= 4_096 else { return false }
        for object in objects {
            guard let container = object as? [String: Any] else { continue }
            if let reference = container["$class"], reference is NSDictionary { return false }
            for key in ["NS.keys", "NS.objects"] {
                if let references = container[key] as? [Any], references.contains(where: { $0 is NSDictionary }) { return false }
            }
        }
        return true
    }

    private enum Invalid: Error { case archive }
    private indirect enum Value {
        case string(String), data(Data), integer(String), real(UInt64), boolean(Bool), date(UInt64)
        case array([Value]), dictionary([(String, Value)])

        var canonical: String {
            func frame(_ value: String) -> String { "\(value.utf8.count):\(value)" }
            switch self {
            case .string(let value): return "s" + frame(value)
            case .data(let value): return "b" + frame(value.base64EncodedString())
            case .integer(let value): return "i" + frame(value)
            case .real(let bits): return "r" + frame(String(bits, radix: 16))
            case .boolean(let value): return value ? "t" : "f"
            case .date(let bits): return "d" + frame(String(bits, radix: 16))
            case .array(let values): return "a\(values.count):" + values.map { frame($0.canonical) }.joined()
            case .dictionary(let entries):
                let sorted = entries.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
                return "m\(entries.count):" + sorted.map { frame($0.0) + frame($0.1.canonical) }.joined()
            }
        }
    }

    private struct Decoder {
        let objects: [Any]
        var seen: Set<Int> = []
        var remaining = 8_192

        mutating func resolve(_ atom: Any, depth: Int, path: Set<Int>) throws -> Value {
            guard depth < 32, remaining > 0 else { throw Invalid.archive }
            remaining -= 1
            guard let uid = atom as? [String: Any], Set(uid.keys) == [uidMarker],
                  let number = uid[uidMarker] as? NSNumber,
                  let raw = integer(number), let index = Int(raw), index > 0,
                  objects.indices.contains(index), !path.contains(index) else { throw Invalid.archive }
            seen.insert(index)
            let object = objects[index]
            if let value = object as? String { return .string(value) }
            if let value = object as? Data { return .data(value) }
            if let value = object as? Date { return .date(value.timeIntervalSinceReferenceDate.bitPattern) }
            if let value = object as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
                if let text = integer(value) { return .integer(text) }
                guard value.doubleValue.isFinite else { throw Invalid.archive }
                return .real(value.doubleValue.bitPattern)
            }
            guard let container = object as? [String: Any],
                  let classRef = container["$class"] as? [String: Any], Set(classRef.keys) == [uidMarker],
                  let classNumber = classRef[uidMarker] as? NSNumber,
                  let rawClass = integer(classNumber), let classIndex = Int(rawClass), classIndex > 0,
                  objects.indices.contains(classIndex), classIndex != index,
                  let descriptor = objects[classIndex] as? [String: Any],
                  Set(descriptor.keys) == ["$classname", "$classes"],
                  let className = descriptor["$classname"] as? String,
                  let classes = descriptor["$classes"] as? [String] else { throw Invalid.archive }
            seen.insert(classIndex)
            // A shared class descriptor is metadata, not a recursively followed
            // object edge. Nested dictionaries may use the same descriptor.
            let next = path.union([index])
            if ["NSDictionary", "NSMutableDictionary"].contains(className) {
                let expected = className == "NSDictionary" ? ["NSDictionary", "NSObject"] : ["NSMutableDictionary", "NSDictionary", "NSObject"]
                guard classes == expected, Set(container.keys) == ["$class", "NS.keys", "NS.objects"],
                      let keys = container["NS.keys"] as? [Any], let values = container["NS.objects"] as? [Any],
                      keys.count == values.count, keys.count <= 4_096 else { throw Invalid.archive }
                var entries: [(String, Value)] = [], unique: Set<Data> = []
                for (key, value) in zip(keys, values) {
                    guard case .string(let name) = try resolve(key, depth: depth + 1, path: next),
                          unique.insert(Data(name.utf8)).inserted else { throw Invalid.archive }
                    entries.append((name, try resolve(value, depth: depth + 1, path: next)))
                }
                return .dictionary(entries)
            }
            if ["NSArray", "NSMutableArray"].contains(className) {
                let expected = className == "NSArray" ? ["NSArray", "NSObject"] : ["NSMutableArray", "NSArray", "NSObject"]
                guard classes == expected, Set(container.keys) == ["$class", "NS.objects"],
                      let values = container["NS.objects"] as? [Any], values.count <= 4_096 else { throw Invalid.archive }
                var result: [Value] = []
                for value in values { result.append(try resolve(value, depth: depth + 1, path: next)) }
                return .array(result)
            }
            throw Invalid.archive
        }
    }
}
