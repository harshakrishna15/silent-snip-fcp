import CutdownCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Replacement is scoped to the one project in a fresh host export. Final Cut
/// matches event/project names and assigns the replacement a new project UID.
public struct XMLReplacementTarget: Codable, Equatable, Sendable {
    public let libraryURL: URL
    public let eventName: String
    public let eventUID: UUID
    public let projectName: String
    public let originalProjectUID: String

    public init(projectData: Data) throws {
        let document = try TimelineParser.parse(data: projectData)
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let projects = try xml.nodes(forXPath: "/fcpxml/library/event/project")
        guard projects.count == 1, let project = projects.first as? XMLElement,
              let event = project.parent as? XMLElement,
              let library = event.parent as? XMLElement,
              let location = library.attribute(forName: "location")?.stringValue,
              let url = URL(string: location), url.isFileURL, url.pathExtension == "fcpbundle",
              let name = event.attribute(forName: "name")?.stringValue, !name.isEmpty,
              let uid = event.attribute(forName: "uid")?.stringValue, let eventID = UUID(uuidString: uid),
              let projectID = document.projectUID, !projectID.isEmpty,
              !document.projectName.isEmpty else {
            throw EditedProjectWriterError.unsupported("replacement needs one project with its original event and library identity")
        }
        libraryURL = url.standardizedFileURL
        eventName = name; eventUID = eventID
        projectName = document.projectName; originalProjectUID = projectID
    }

    func verifyDestination(_ data: Data) throws {
        let actual = try Self(projectData: data)
        guard actual.libraryURL == libraryURL, actual.eventName == eventName,
              actual.eventUID == eventUID, actual.projectName == projectName,
              actual.originalProjectUID != originalProjectUID else {
            throw EditedProjectWriterError.verificationFailed("the replacement is not the new project in the original event and library")
        }
    }
}
