import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum ProjectRecoverySnapshot {
    static func recovery(data: Data, name: String) throws -> Data {
        let baseline = try TimelineParser.parse(data: data)
        let xml = try XMLDocument(data: data, options: [.nodePreserveAll])
        guard let project = try xml.nodes(forXPath: "//project").first as? XMLElement else {
            throw EditedProjectWriterError.verificationFailed("missing recovery project")
        }
        project.attribute(forName: "name")?.stringValue = name
        project.attribute(forName: "uid")?.stringValue = UUID().uuidString
        if project.attribute(forName: "uid") == nil {
            project.addAttribute(XMLNode.attribute(withName: "uid", stringValue: UUID().uuidString) as! XMLNode)
        }
        let result = xml.xmlData
        let restored = try TimelineParser.parse(data: result)
        guard restored.fingerprint == baseline.fingerprint,
              restored.projectUID != baseline.projectUID else {
            throw EditedProjectWriterError.verificationFailed("recovery snapshot differs from original")
        }
        return result
    }

}
