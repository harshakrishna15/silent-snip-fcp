import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// An exported effect reference is not proof that its native settings can be
/// reconstructed. In particular, Final Cut can omit the advanced AU state of
/// its audio-effect wrappers while still exporting their outer controls.
///
/// No general reconstruction schema has passed a native settings-preservation
/// check. Every rendering audio filter needs its existing native instance,
/// regardless of effect name, UID format, bypass state or exported payload.
/// A plausible archive is serialization evidence, not proof of complete state.
/// Only the exact, known passthrough Silent Snip controller is exempt.
enum EditableEffectReconstruction {
    /// The writer has already validated these bytes with the bounded parser.
    static func validate(projectData: Data) throws {
        let xml = try XMLDocument(data: projectData, options: [.nodeLoadExternalEntitiesNever])
        let resources = try xml.nodes(forXPath: "/fcpxml/resources/effect").compactMap { $0 as? XMLElement }
        let filters = try xml.nodes(forXPath: "//project/sequence//filter-audio").compactMap { $0 as? XMLElement }
        for filter in filters {
            let filterName = filter.attribute(forName: "name")?.stringValue
            guard let ref = filter.attribute(forName: "ref")?.stringValue,
                  let resource = resources.first(where: { $0.attribute(forName: "id")?.stringValue == ref }),
                  let uid = resource.attribute(forName: "uid")?.stringValue,
                  !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw incompleteState(filterName ?? "Audio Effect")
            }
            if uid == AudioControllerSettings.effectUID { continue }
            let name = filterName
                ?? resource.attribute(forName: "name")?.stringValue ?? "Audio Effect"
            throw incompleteState(name)
        }
    }

    private static func incompleteState(_ name: String) -> EditedProjectWriterError {
        .unsupported("Final Cut Pro did not export verifiable original settings for the ‘\(name)’ audio effect. Silent Snip cannot safely recreate its editable controls. Make the cuts in Final Cut Pro to retain this effect; no cleaned project was sent.")
    }
}
