import Foundation

/// A single writer for a caller-owned JSON file. It has no default location and
/// does not use UserDefaults or any Final Cut preference domain. Share one
/// instance per file; a save rereads the archive before changing one project.
public actor WorkflowSettingsStore {
    public static let schemaVersion = 1
    public let fileURL: URL

    public init(fileURL: URL) throws {
        guard WorkflowProjectIdentity.isLocalFileURL(fileURL), !fileURL.hasDirectoryPath,
              !fileURL.lastPathComponent.isEmpty else {
            throw WorkflowModelError.invalidStoreURL
        }
        self.fileURL = URL(fileURLWithPath: fileURL.path, isDirectory: false).standardizedFileURL
    }

    /// Nil means either an unbound context or no saved settings for this exact
    /// identity. A damaged archive throws instead of supplying replacement
    /// defaults or allowing the next save to overwrite it.
    public func settings(for identity: WorkflowProjectIdentity?) throws -> WorkflowSettings? {
        guard let identity else { return nil }
        return try readArchive().projects.first(where: { $0.identity == identity })?.settings
    }

    public func save(_ settings: WorkflowSettings, for identity: WorkflowProjectIdentity?) throws {
        // Reject an unbound project before reading, creating directories, or
        // writing anything, even when a same-named project was previously open.
        guard let identity else { throw WorkflowModelError.unboundProject }
        var archive = try readArchive()
        if let index = archive.projects.firstIndex(where: { $0.identity == identity }) {
            archive.projects[index] = Entry(identity: identity, settings: settings)
        } else {
            archive.projects.append(Entry(identity: identity, settings: settings))
        }
        archive.projects.sort {
            if $0.identity.libraryURL != $1.identity.libraryURL {
                return $0.identity.libraryURL.absoluteString < $1.identity.libraryURL.absoluteString
            }
            return $0.identity.projectUID < $1.identity.projectUID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(archive)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func readArchive() throws -> Archive {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                return Archive(projects: [])
            }
            throw error
        }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == Self.schemaVersion else {
                throw WorkflowModelError.unsupportedSchema(archive.schemaVersion)
            }
            guard Set(archive.projects.map(\.identity)).count == archive.projects.count else {
                throw WorkflowModelError.invalidArchive
            }
            return archive
        } catch let error as WorkflowModelError {
            // Value and identity validation errors still fail the whole
            // archive; no partially recovered projects are adopted.
            throw error
        } catch {
            throw WorkflowModelError.invalidArchive
        }
    }

    private struct Entry: Codable {
        let identity: WorkflowProjectIdentity
        let settings: WorkflowSettings
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        var projects: [Entry]

        init(projects: [Entry]) {
            schemaVersion = WorkflowSettingsStore.schemaVersion
            self.projects = projects
        }
    }
}
