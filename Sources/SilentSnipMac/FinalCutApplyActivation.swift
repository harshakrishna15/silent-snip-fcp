import AppKit
import Foundation

/// Prevent the headless worker from taking focus when Final Cut delivers a
/// Share Open Document event during Apply. Host windows and input guards stay
/// unchanged. Restore the caller's exact policy before returning any outcome.
@MainActor public enum FinalCutApplyActivation {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func run<T>(readPolicy: () -> NSApplication.ActivationPolicy,
                              setPolicy: (NSApplication.ActivationPolicy) -> Bool,
                              operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let prior = readPolicy()
        if prior != .prohibited {
            let accepted = setPolicy(.prohibited)
            let observed = readPolicy()
            guard accepted, observed == .prohibited else {
                let restored = restore(prior, readPolicy: readPolicy, setPolicy: setPolicy)
                let extra = restored ? "" : " Its previous activation policy could not be restored."
                throw Failure(message: "Silent Snip could not prevent its worker from taking keyboard focus. Apply did not start." + extra)
            }
        }

        let outcome: Result<T, Error>
        do { outcome = .success(try await operation()) }
        catch { outcome = .failure(error) }

        guard restore(prior, readPolicy: readPolicy, setPolicy: setPolicy) else {
            let original: String
            if case .failure(let error) = outcome { original = " Apply reported: \(error.localizedDescription)" }
            else { original = " Check the existing result before starting another Apply." }
            throw Failure(message: "Silent Snip could not restore its previous activation policy after Apply." + original)
        }
        return try outcome.get()
    }

    private static func restore(_ prior: NSApplication.ActivationPolicy,
                                readPolicy: () -> NSApplication.ActivationPolicy,
                                setPolicy: (NSApplication.ActivationPolicy) -> Bool) -> Bool {
        guard readPolicy() != prior else { return true }
        let accepted = setPolicy(prior)
        let observed = readPolicy()
        return accepted && observed == prior
    }
}
