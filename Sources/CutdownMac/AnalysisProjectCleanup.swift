import Foundation
import CutdownCore

enum AnalysisProjectCleanup {
    /// Cleanup is limited to this request's generated project, after its actual
    /// host delivery was verified and the original project is open again.
    static func validate(isolated: IsolatedAudioProject, delivered: Data, currentProject: String) throws {
        let prefix = "Cutdown Analysis "
        guard isolated.name.hasPrefix(prefix),
              UUID(uuidString: String(isolated.name.dropFirst(prefix.count))) != nil,
              currentProject != isolated.name,
              try TimelineParser.parse(data: isolated.data).projectName == isolated.name,
              try ProjectRoundTripVerification.compare(expected: isolated.data, actual: delivered,
                  allowHostAssignedIdentity: true).verified else {
            throw FinalCutCaptureError.unavailable("Temporary project ownership could not be verified; it was left in place.")
        }
    }
}
