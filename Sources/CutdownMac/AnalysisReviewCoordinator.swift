import CutdownCore
import Foundation

public struct ReviewAnalysisResult: Sendable {
    public var analyzed: AnalyzedAudioProject
    public let dropFrame: Bool
    public let presentationNotice: String?
    public init(analyzed: AnalyzedAudioProject, dropFrame: Bool = false, presentationNotice: String? = nil) {
        self.analyzed = analyzed
        self.dropFrame = dropFrame
        self.presentationNotice = presentationNotice
    }
}

/// Owns analysis and editing independently of the effect view. The local review
/// channel cannot provide an edit operation; the application must inject one
/// that validates the current project and owns recovery for native edits.
@MainActor public final class AnalysisReviewCoordinator {
    public typealias Progress = @MainActor (String, Double?) -> Void
    public typealias Operation = @MainActor (AnalyzeRequest, @escaping Progress) async throws -> ReviewAnalysisResult
    public typealias ApplyOperation = @MainActor (AnalyzeRequest, ReviewAnalysisResult, @escaping Progress) async throws -> Void

    public typealias HighlightOperation = @MainActor (AnalyzeRequest, ReviewAnalysisResult, String) async throws -> Void
    public typealias VerificationOperation = @MainActor (AnalyzeRequest, @escaping Progress) async throws -> Void

    private final class Job {
        let request: AnalyzeRequest
        var revision = 0
        var state: ReviewState = .analyzing
        var message = "Starting analysis…"
        var progress: Double? = 0
        var result: ReviewAnalysisResult?
        var task: Task<Void, Never>?
        var publication: ReviewPublication?
        var cancelled = false
        var applyStarted = false
        init(_ request: AnalyzeRequest) { self.request = request }
    }

    private let operation: Operation
    private let applyOperation: ApplyOperation?
    private let authorizeApply: @MainActor (ReviewCommand) -> Bool
    private let highlightOperation: HighlightOperation?
    private let verificationOperation: VerificationOperation?
    private let canRetryVerification: (UUID) -> Bool
    private let emit: (ReviewPublication) throws -> Void
    private let receiveLocal: ((ReviewResponse) -> Void)?
    private let record: (AnalyzeRequest, String, String) -> Void
    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var active: UUID?

    public init(operation: @escaping Operation, applyOperation: ApplyOperation? = nil,
                authorizeApply: @escaping @MainActor (ReviewCommand) -> Bool = { _ in false },
                highlightOperation: HighlightOperation? = nil,
                verificationOperation: VerificationOperation? = nil,
                canRetryVerification: @escaping (UUID) -> Bool = { _ in false },
                emit: @escaping (ReviewPublication) throws -> Void,
                receiveLocal: ((ReviewResponse) -> Void)? = nil,
                record: @escaping (AnalyzeRequest, String, String) -> Void = { request, state, message in
                    try? IntegrationReport(request: request, state: state, message: message).save()
                }) {
        self.operation = operation
        self.applyOperation = applyOperation
        self.authorizeApply = authorizeApply
        self.highlightOperation = highlightOperation
        self.verificationOperation = verificationOperation
        self.canRetryVerification = canRetryVerification
        self.emit = emit
        self.receiveLocal = receiveLocal
        self.record = record
    }

    public var isBusy: Bool { jobs.values.contains { $0.task != nil } }

    /// A verified plan may be displayed while the operation still owns cleanup.
    /// No review mutations or Apply are accepted until the operation completes.
    public func previewReady(_ id: UUID, result: ReviewAnalysisResult) {
        guard active == id, let job = jobs[id], job.state == .analyzing,
              !job.cancelled, job.task != nil else { return }
        job.result = result
        job.message = "Preview ready. Finishing analysis cleanup…"
        publish(job)
    }
    var retainedJobCount: Int { jobs.count }

    public func start(_ request: AnalyzeRequest) {
        if let existing = jobs[request.id] { resend(existing); return }
        let job = Job(request)
        jobs[request.id] = job
        order.append(request.id)
        if let active, let previous = jobs[active] {
            if previous.task != nil || previous.state.isBusy {
                job.state = .failed
                job.message = previous.applyStarted
                    ? "Cutdown is still applying or stopping cuts. Wait for it to finish, then Analyze again."
                    : "Another Cutdown analysis is running. Cancel it or wait for it to finish, then Analyze again."
                publish(job)
                prune()
                return
            }
            previous.result = nil
            previous.cancelled = true
            previous.state = .cancelled
            previous.message = "A new analysis replaced this review."
            publish(previous)
        }
        active = request.id
        publish(job)
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                let result = try await operation(request) { [weak self, weak job] message, progress in
                    guard let self, let job, !job.cancelled, job.state == .analyzing else { return }
                    job.message = message
                    job.progress = progress
                    self.publish(job)
                }
                try Task.checkCancellation()
                guard !job.cancelled else { throw CancellationError() }
                job.result = result
                job.state = .review
                job.progress = 1
                job.message = self.reviewMessage(result)
            } catch {
                job.result = nil
                job.progress = nil
                if job.cancelled || error is CancellationError {
                    job.state = .cancelled
                    job.message = "Analysis cancelled. No timeline edits were made."
                } else {
                    job.state = .failed
                    job.message = error.localizedDescription
                }
            }
            job.task = nil
            if job.state != .review, active == request.id { active = nil }
            publish(job)
            record(request, job.state.rawValue, job.message)
            prune()
        }
    }

    public func handle(_ command: ReviewCommand) {
        // Notifications are broadcast to every running helper. Only the owner
        // may answer: an unrelated helper must not overwrite the real response
        // or poison its revision. A lost owner is handled by the view's timeout.
        guard let job = jobs[command.request] else { return }
        if command.command == .status { resend(job); return }
        if command.command == .retryVerification {
            if let expected = command.expectedRevision, expected != job.revision {
                resend(job)
                return
            }
            guard job.state.canRetryVerification else { resend(job); return }
            if !beginVerification(job) {
                // A handled but currently unavailable command needs a new
                // response too, so the remote view can release its pending retry.
                job.message = "Verification could not start. Finish the current operation or review, then retry the existing result."
                publish(job)
            }
            return
        }
        if command.command == .cancel {
            guard active == command.request, job.state.canCancel else { return }
            job.cancelled = true
            job.result = nil
            job.task?.cancel()
            job.state = job.task == nil ? .cancelled : .cancelling
            if job.applyStarted {
                job.message = "Stopping Apply. The project may already have been replaced in Final Cut. Check the result or recovery XML before applying again…"
            } else {
                job.message = job.task == nil ? "Review cancelled. No timeline edits were made." : "Stopping the export safely…"
            }
            job.progress = nil
            if job.task == nil, active == job.request.id { active = nil }
            publish(job)
            return
        }
        guard active == command.request, job.state == .review, var result = job.result else { return }
        if let expected = command.expectedRevision, expected != job.revision {
            resend(job)
            return
        }
        do {
            switch command.command {
            case .preview:
                // Older Audio Unit windows can still send this command while
                // Final Cut is running. A valid review always keeps its lines.
                guard command.included != nil else { return }
            case .include:
                guard let id = command.cutID, let included = command.included else { return }
                try result.analyzed.review.setIncluded(included, cutID: id)
            case .selectAll: result.analyzed.review.selectAllEligible(true)
            case .deselectAll: result.analyzed.review.selectAllEligible(false)
            case .highlight:
                guard let id = command.cutID else { return }
                guard result.analyzed.review.cuts.contains(where: { $0.id == id }) else { throw ReviewError.unknownCut }
                beginHighlight(job, result: result, cutID: id)
                return
            case .apply:
                guard applyOperation != nil else {
                    beginApply(job, result: result)
                    return
                }
                guard authorizeApply(command) else {
                    job.result = nil
                    job.state = .failed
                    job.message = "Apply was not confirmed in the selected Cutdown Controls window. Analyze again before applying cuts."
                    if active == job.request.id { active = nil }
                    publish(job)
                    record(job.request, job.state.rawValue, job.message)
                    return
                }
                beginApply(job, result: result)
                return
            case .status, .cancel, .retryVerification: return
            }
            job.result = result
            job.message = self.reviewMessage(result)
            publish(job)
        } catch {
            // A bad review command must not discard valid, previously computed
            // candidates or silently reset the user's inclusion choices.
            job.message = error.localizedDescription
            publish(job)
        }
    }

    private func beginHighlight(_ job: Job, result: ReviewAnalysisResult, cutID: String) {
        guard let highlightOperation else { return }
        job.state = .navigating
        job.message = "Moving to the selected cut…"
        job.progress = nil
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                try await highlightOperation(job.request, result, cutID)
                try Task.checkCancellation()
                job.message = "Playhead moved to the selected cut’s start."
            } catch {
                job.message = error.localizedDescription
                if error is XMLProjectBaselineError || Self.invalidatesReview(error) {
                    job.result = nil
                    job.state = .failed
                }
            }
            job.task = nil
            if job.cancelled {
                job.state = .cancelled; job.result = nil
                if active == job.request.id { active = nil }
            } else if job.result == nil {
                job.state = .failed
                if active == job.request.id { active = nil }
            } else { job.state = .review }
            publish(job)
            prune()
        }
        publish(job)
    }

    private static func invalidatesReview(_ error: Error) -> Bool {
        if case FinalCutCaptureError.changedProject = error { return true }
        if case ReviewError.staleProject = error { return true }
        return false
    }

    public func restoreVerification(_ request: AnalyzeRequest) {
        guard !isBusy, canRetryVerification(request.id) else { return }
        if let active, let previous = jobs[active] {
            previous.result = nil; previous.cancelled = true; previous.state = .cancelled
            previous.message = "Review closed to verify an existing result."
            publish(previous)
        }
        active = nil
        let job = Job(request)
        job.state = .failed; job.applyStarted = true
        job.revision = jobs[request.id]?.revision ?? 0
        jobs[request.id] = job
        order.removeAll { $0 == request.id }; order.append(request.id)
        beginVerification(job)
        prune()
    }

    @discardableResult private func beginVerification(_ job: Job) -> Bool {
        guard let verificationOperation, canRetryVerification(job.request.id),
              job.state.canRetryVerification, !isBusy,
              active == nil || active == job.request.id else { return false }
        active = job.request.id
        job.cancelled = false
        job.state = .verifying
        job.message = "Checking the existing imported result…"
        job.progress = nil
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                try await verificationOperation(job.request) { [weak self, weak job] message, fraction in
                    guard let self, let job, !job.cancelled, job.state == .verifying else { return }
                    job.message = message; job.progress = fraction; self.publish(job)
                }
                try Task.checkCancellation()
                job.state = .completed; job.progress = 1
            } catch {
                job.state = job.cancelled ? .cancelled : .failed
                job.message = "Verification stopped: " + error.localizedDescription
                job.progress = nil
            }
            job.task = nil
            if active == job.request.id { active = nil }
            publish(job)
            record(job.request, job.state.rawValue, job.message)
            prune()
        }
        publish(job)
        return true
    }

    public func stop() {
        for job in jobs.values { job.cancelled = true; job.task?.cancel() }
    }

    private func beginApply(_ job: Job, result: ReviewAnalysisResult) {
        guard let applyOperation else {
            job.message = "Apply is not connected in this build."
            publish(job)
            return
        }
        if let reason = Self.applyUnavailableReason(result) {
            job.message = reason
            publish(job)
            return
        }
        // Capture the current inclusion choices once. Neither another command
        // nor a late settings change can alter the operation already dispatched.
        let selectedCount = result.analyzed.review.selectedCuts.count
        job.applyStarted = true
        job.result = nil
        job.state = .applying
        job.message = "Checking the project before applying \(selectedCount) selected cuts…"
        job.progress = 0
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                try Task.checkCancellation()
                try await applyOperation(job.request, result) { [weak self, weak job] message, progress in
                    guard let self, let job, !job.cancelled, job.state == .applying else { return }
                    job.message = message
                    job.progress = progress
                    self.publish(job)
                }
                try Task.checkCancellation()
                guard !job.cancelled else { throw CancellationError() }
                job.state = .completed
                if job.progress != 1 { job.message = "Apply completed for \(selectedCount) selected cuts." }
                job.progress = 1
            } catch {
                job.progress = nil
                if job.cancelled || error is CancellationError {
                    job.state = .cancelled
                    job.message = "Apply cancelled. " + error.localizedDescription
                } else {
                    job.state = .failed
                    job.message = "Apply stopped: \(error.localizedDescription)"
                }
            }
            job.task = nil
            if active == job.request.id { active = nil }
            publish(job)
            record(job.request, job.state.rawValue, job.message)
            prune()
        }
        publish(job)
    }

    public var onReviewChange: ((UUID, ReviewPlan?) -> Void)?

    private func publish(_ job: Job) {
        // Publish the preview only after a valid review reaches a presentation
        // channel. Local observers do not depend on the plugin transport.
        defer {
            if active == nil || active == job.request.id {
                let retainsPreview = job.state == .review || job.state == .analyzing || job.state == .navigating
                onReviewChange?(job.request.id, active == job.request.id && retainsPreview ? job.result?.analyzed.review : nil)
            }
        }
        job.revision += 1
        do {
            let response = try makeResponse(job)
            // Check payload size before caching: a status poll must always be
            // able to receive the same complete, bounded response.
            let publication = try ReviewPublication(response)
            job.publication = publication
            try deliver(publication)
        } catch {
            job.task?.cancel()
            job.result = nil
            job.state = .failed
            job.progress = nil
            job.message = "The review could not be displayed: \(error.localizedDescription)"
            let response = ReviewResponse(request: job.request.id, revision: job.revision,
                state: "failed", message: job.message)
            job.publication = try? ReviewPublication(response)
            if let publication = job.publication { try? deliver(publication) }
        }
    }

    private func resend(_ job: Job) {
        if let publication = job.publication { try? deliver(publication) }
    }

    private func deliver(_ publication: ReviewPublication) throws {
        receiveLocal?(publication.response)
        do { try emit(publication) }
        catch {
            // Keep the job and cached response usable through the helper.
            // A subsequent status poll retries the plugin channel.
            if receiveLocal == nil { throw error }
        }
    }

    private func makeResponse(_ job: Job) throws -> ReviewResponse {
        guard let result = job.result, job.state == .review || job.state == .analyzing else {
            return ReviewResponse(request: job.request.id, revision: job.revision,
                state: job.state.rawValue, message: job.message, progress: job.progress,
                canCancel: job.state.canCancel,
                canRetryVerification: verificationOperation != nil && job.state.canRetryVerification && canRetryVerification(job.request.id))
        }
        let analysis = result.analyzed
        let review = analysis.review
        guard review.cuts.count <= 1_000 else { throw CoordinatorError.tooManyCuts }
        let cuts = try review.cuts.map { cut in
            ReviewCutResponse(id: cut.id,
                start: try timecode(cut.range.start, analysis: analysis, dropFrame: result.dropFrame),
                end: try timecode(cut.range.end, analysis: analysis, dropFrame: result.dropFrame),
                duration: Self.seconds(try cut.range.checkedDuration()), included: cut.included,
                eligible: cut.isEligible, reason: cut.unavailableReason)
        }
        let removed = try review.selectedDuration
        let duration = try review.target.timelineRange.checkedDuration()
        let gap = try job.request.outputMode.gapDuration(frame: analysis.document.frameDuration)
        let added = try (gap ?? .zero).multiplied(by: RationalTime(Int64(review.selectedCuts.count)))
        let after = try duration.subtracting(removed).adding(added)
        let summary = gap == nil
            ? "\(review.selectedCuts.count) selected · \(Self.seconds(removed)) removed · \(Self.seconds(duration)) → \(Self.seconds(after))"
            : "\(review.selectedCuts.count) gaps × \(Self.seconds(gap!)) · \(Self.seconds(duration)) → \(Self.seconds(after))"
        let ready = job.state == .review
        return ReviewResponse(request: job.request.id, revision: job.revision, state: job.state.rawValue,
            message: job.message, progress: 1, summary: summary, cuts: cuts,
            canApply: ready && applyOperation != nil && Self.applyUnavailableReason(result) == nil,
            canChangeSelection: ready, canCancel: true, canHighlight: ready && highlightOperation != nil, previewVisible: true)
    }

    private func timecode(_ value: RationalTime, analysis: AnalyzedAudioProject, dropFrame: Bool) throws -> String {
        try FinalCutTimecode.format(value.adding(analysis.document.projectTimecodeStart),
            frameDuration: analysis.document.frameDuration, dropFrame: dropFrame)
    }

    private static func seconds(_ time: RationalTime) -> String { String(format: "%.3f s", time.seconds) }

    private func reviewMessage(_ result: ReviewAnalysisResult) -> String {
        let message = Self.applyUnavailableReason(result) ?? Self.reviewMessage(result.analyzed.analysis.disposition, applyAvailable: applyOperation != nil)
        // Empty reviews retain their specific no-silence/whole-clip explanation.
        let explanation = result.analyzed.review.cuts.isEmpty ? Self.reviewMessage(result.analyzed.analysis.disposition, applyAvailable: applyOperation != nil) : message
        return [explanation, result.presentationNotice].compactMap { $0 }.joined(separator: " ")
    }

    private static func reviewMessage(_ disposition: SilenceAnalysisDisposition, applyAvailable: Bool) -> String {
        switch disposition {
        case .cuts:
            return applyAvailable
                ? "Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts."
                : "Analysis complete. Review the proposed ranges below. Apply is not connected in this build."
        case .noSilence: return "No qualifying silence was found. No cuts are proposed."
        case .entirelySilent: return "The selected recording is entirely below the threshold. Whole-clip deletion is unavailable."
        }
    }

    private static func applyUnavailableReason(_ result: ReviewAnalysisResult) -> String? {
        let analysis = result.analyzed
        let isolatedAudio = analysis.dialogueContext.sourceRange != nil || analysis.dialogueContext.isolatedTargetID != nil
        let warnings = analysis.document.warnings.filter { !isolatedAudio || $0 != TimelineDocument.missingDialogueWarning }
        guard warnings.isEmpty else {
            return "Apply is unavailable because the project has unresolved issues: " + warnings.joined(separator: "; ")
        }
        let target = analysis.review.target
        guard target.enabled, target.isPrimaryStoryline, !target.hasVideo, target.hasAudio,
              target.unsupportedReasons.isEmpty else {
            return "Apply requires a supported, enabled audio-only clip in the primary storyline."
        }
        guard !analysis.review.selectedCuts.isEmpty else { return "Select at least one eligible cut before applying." }
        return nil
    }

    private func prune() {
        while order.count > 24 {
            guard let index = order.firstIndex(where: { $0 != active && jobs[$0]?.task == nil }) else { return }
            jobs.removeValue(forKey: order.remove(at: index))
        }
    }

    private enum CoordinatorError: LocalizedError {
        case tooManyCuts
        var errorDescription: String? { "There are more than 1,000 proposed cuts. Increase Minimum Silence and Analyze again." }
    }
}
