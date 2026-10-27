import Foundation

/// Monotonic stage timing, including failed/cancelled attempts. File paths and
/// media contents are not included in the report.
@MainActor final class AnalysisTiming {
    struct Report: Codable {
        let request: UUID
        let outcome: String
        let cache: String
        let totalSeconds: Double
        let previewReadySeconds: Double?
        let stages: [String: Double]
        let details: [String: Double]
        let counters: [String: Int]
    }
    private let request: UUID
    private let clock: () -> Double
    private let start: Double
    private var stageStart: Double
    private var stage: String?
    private var stages: [String: Double] = [:]
    private var previewReady: Double?
    private var details: [String: Double] = [:]
    private var counters: [String: Int] = [:]
    var cache = "not checked"
    init(request: UUID, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.request = request; self.clock = clock
        start = clock(); stageStart = start
    }
    func begin(_ name: String) {
        let now = clock()
        if let stage { stages[stage, default: 0] += max(0, now - stageStart) }
        stage = name; stageStart = now
    }
    func markPreviewReady() { previewReady = max(0, clock() - start) }
    func measure<T>(_ name: String, operation: () throws -> T) rethrows -> T {
        let start = clock()
        defer { details[name, default: 0] += max(0, clock() - start) }
        return try operation()
    }
    func measure<T>(_ name: String, operation: () async throws -> T) async rethrows -> T {
        let start = clock()
        defer { details[name, default: 0] += max(0, clock() - start) }
        return try await operation()
    }
    func recordCounters(_ values: [String: Int]) { counters.merge(values, uniquingKeysWith: { _, new in new }) }
    func report(outcome: String) -> Report {
        var totals = stages
        let now = clock()
        if let stage { totals[stage, default: 0] += max(0, now - stageStart) }
        return Report(request: request, outcome: outcome, cache: cache, totalSeconds: max(0, now - start),
            previewReadySeconds: previewReady, stages: totals, details: details, counters: counters)
    }
    func save(to url: URL, outcome: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report(outcome: outcome)) { try? data.write(to: url, options: .atomic) }
    }
}
