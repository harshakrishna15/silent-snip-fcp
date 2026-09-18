import AppKit
import Carbon

/// Cocoa Scripting conversion hooks required by Apple's Media Asset Protocol.
/// Keep actual lists and booleans rather than converting metadata to display text.
extension NSDictionary {
    @objc(scriptingUserDefinedRecordWithDescriptor:)
    public class func scriptingUserDefinedRecord(with descriptor: NSAppleEventDescriptor) -> NSDictionary {
        guard let fields = descriptor.forKeyword(AEKeyword(keyASUserRecordFields)) else { return [:] }
        var values: [String: Any] = [:]
        if fields.numberOfItems >= 2 {
            for index in stride(from: 1, to: fields.numberOfItems, by: 2) {
                if let key = fields.atIndex(index)?.stringValue, let value = fields.atIndex(index + 1)?.cutdownObjectValue {
                    values[key] = value
                }
            }
        }
        return values as NSDictionary
    }

    @objc public func scriptingUserDefinedRecordDescriptor() -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.record()
        let fields = NSAppleEventDescriptor.list()
        for key in allKeys.compactMap({ $0 as? String }).sorted() {
            guard let value = self[key] else { continue }
            fields.insert(NSAppleEventDescriptor(string: key), at: 0)
            fields.insert(NSAppleEventDescriptor.cutdownDescriptor(with: value), at: 0)
        }
        descriptor.setDescriptor(fields, forKeyword: AEKeyword(keyASUserRecordFields))
        return descriptor
    }
}

extension NSAppleEventDescriptor {
    static func cutdownDescriptor(with object: Any) -> NSAppleEventDescriptor {
        if let record = object as? NSDictionary { return record.scriptingUserDefinedRecordDescriptor() }
        if let list = object as? [Any] {
            let result = NSAppleEventDescriptor.list()
            list.forEach { result.insert(cutdownDescriptor(with: $0), at: 0) }
            return result
        }
        if let text = object as? String { return NSAppleEventDescriptor(string: text) }
        if let url = object as? URL { return NSAppleEventDescriptor(fileURL: url) }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
            return NSAppleEventDescriptor(double: number.doubleValue)
        }
        return NSAppleEventDescriptor.null()
    }

    var cutdownObjectValue: Any? {
        switch descriptorType {
        case typeAERecord: return NSDictionary.scriptingUserDefinedRecord(with: self)
        case typeAEList:
            return numberOfItems == 0 ? [] : (1...numberOfItems).compactMap { atIndex($0)?.cutdownObjectValue }
        case typeFileURL: return fileURLValue
        case typeTrue, typeFalse, typeBoolean: return booleanValue
        case typeSInt16, typeSInt32, typeUInt32: return int32Value
        case typeSInt64, typeUInt64, typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint: return doubleValue
        default: return stringValue
        }
    }
}

@objc(CutdownShareOpenCommand) public final class ShareDestinationOpenCommand: NSScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            let manager = ShareDestinationManager.shared
            guard let direct = appleEvent?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
                scriptErrorNumber = -1708; return nil
            }
            let items = direct.descriptorType == typeAEList
                ? (0..<direct.numberOfItems).compactMap { direct.atIndex($0 + 1) } : [direct]
            let urls = items.compactMap { $0.fileURLValue ?? $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue }
            manager.record("open-event", asset: nil, details: ["fileCount": urls.count])
            if urls.isEmpty || urls.count != items.count || !manager.handleOpen(urls: urls) {
                scriptErrorNumber = -1708
            }
            return nil
        }
    }
}
