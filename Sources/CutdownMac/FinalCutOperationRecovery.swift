import Foundation

/// Normal capture preserves the window's existing identity. Recovery deliberately
/// selects a separately verified segment and must bind a new window identity.
struct FinalCutReviewOwnership {
    struct Suspended {
        let title: String
        var selection: FinalCutSelectionSnapshot?
    }
    var suspended: Suspended?
    private(set) var active: FinalCutSelectionSnapshot?

    mutating func remember(_ selection: FinalCutSelectionSnapshot) throws {
        if var previous = suspended {
            guard selection.clipName == previous.title,
                  previous.selection == nil || previous.selection == selection else {
                throw FinalCutCaptureError.invalidSelection("The selected timeline clip no longer matches the suspended Cutdown review.")
            }
            previous.selection = selection
            suspended = previous
        }
        active = selection
    }

    mutating func bindVerifiedRecovery(_ selection: FinalCutSelectionSnapshot) {
        active = selection
        suspended = Suspended(title: selection.clipName, selection: selection)
    }
}

enum CutdownSettingText {
    static func formatter(locale: Locale = .current) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        // Nine significant decimal digits round-trip every finite Float32 AUValue,
        // including tiny padding values. Fractional-digit limits cannot do that.
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 9
        return formatter
    }
}

enum FinalCutOwnedInput {
    /// Cleanup must be able to run even when the operation's task was cancelled.
    /// Its caller verifies exact field, project and focus ownership before input.
    @MainActor static func perform(operation: () async throws -> Void,
                                   cleanup: @escaping @MainActor () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            let original = error
            let cleanupError = await Task { @MainActor () -> Error? in
                do { try await cleanup(); return nil }
                catch { return error }
            }.value
            if let cleanupError {
                throw FinalCutCaptureError.reviewRestoration(original: original.localizedDescription,
                    guidance: "Timecode entry cleanup could not finish: \(cleanupError.localizedDescription)")
            }
            throw original
        }
    }
}
