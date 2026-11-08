import AppKit
import Foundation
import XCTest
@testable import SilentSnipMac

@MainActor final class FinalCutApplyActivationTests: XCTestCase {
    private typealias Policy = NSApplication.ActivationPolicy
    private struct OperationFailure: LocalizedError {
        var errorDescription: String? { "Original Apply failure" }
    }

    func testSuccessRunsOnlyWhileProhibitedAndRestoresExactPriorPolicy() async throws {
        for prior in [Policy.accessory, .regular] {
            var policy = prior, writes: [Policy] = []
            let value = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: {
                writes.append($0); policy = $0; return true
            }, operation: {
                XCTAssertEqual(policy, .prohibited)
                await Task.yield()
                XCTAssertEqual(policy, .prohibited)
                return 42
            })
            XCTAssertEqual(value, 42)
            XCTAssertEqual(policy, prior)
            XCTAssertEqual(writes, [.prohibited, prior])
        }
    }

    func testOriginalOperationErrorPropagatesAfterRestoration() async throws {
        var policy = Policy.accessory
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: {
                policy = $0; return true
            }, operation: { throw OperationFailure() })
            XCTFail("The operation failure must escape")
        } catch is OperationFailure {
            XCTAssertEqual(policy, .accessory)
        }
    }

    func testCancellationRestoresBeforePropagatingCancellation() async throws {
        var policy = Policy.accessory
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: {
                policy = $0; return true
            }, operation: { throw CancellationError() })
            XCTFail("Cancellation must escape")
        } catch is CancellationError {
            XCTAssertEqual(policy, .accessory)
        }
    }

    func testAlreadyProhibitedNestedOperationNeedsNoPolicyWrites() async throws {
        let value = try await FinalCutApplyActivation.run(readPolicy: { .prohibited }, setPolicy: { _ in
            XCTFail("An already prohibited caller needs no policy transition")
            return false
        }, operation: { "nested" })
        XCTAssertEqual(value, "nested")
    }

    func testRefusedEntryNeverRunsAndRestoresAnyPartialTransition() async throws {
        for partialChange in [false, true] {
            var policy = Policy.accessory, writes: [Policy] = []
            do {
                let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                    writes.append(desired)
                    if desired == .prohibited {
                        if partialChange { policy = desired }
                        return false
                    }
                    policy = desired; return true
                }, operation: {
                    XCTFail("A refused transition cannot authorize Apply")
                    return 0
                })
                XCTFail("Refused entry must fail")
            } catch let error as FinalCutApplyActivation.Failure {
                XCTAssertTrue(error.localizedDescription.contains("Apply did not start"))
                XCTAssertEqual(policy, .accessory)
                XCTAssertEqual(writes, partialChange ? [.prohibited, .accessory] : [.prohibited])
            }
        }
    }

    func testSuccessfulSetterWithWrongReadbackNeverAuthorizesApply() async throws {
        var policy = Policy.accessory, writes: [Policy] = []
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                writes.append(desired)
                policy = desired == .prohibited ? .regular : desired
                return true
            }, operation: {
                XCTFail("The readback must prove suppression before Apply")
                return 0
            })
            XCTFail("Incorrect entry readback must fail")
        } catch let error as FinalCutApplyActivation.Failure {
            XCTAssertTrue(error.localizedDescription.contains("Apply did not start"))
            XCTAssertEqual(policy, .accessory)
            XCTAssertEqual(writes, [.prohibited, .accessory])
        }
    }

    func testRefusedRestorationSurfacesFailureAfterSuccessfulOperation() async throws {
        var policy = Policy.accessory, operations = 0
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                guard desired == .prohibited else { return false }
                policy = desired; return true
            }, operation: { operations += 1; return 42 })
            XCTFail("A completed operation cannot hide failed restoration")
        } catch let error as FinalCutApplyActivation.Failure {
            XCTAssertTrue(error.localizedDescription.contains("restore its previous activation policy"))
            XCTAssertTrue(error.localizedDescription.contains("Check the existing result"))
            XCTAssertEqual(operations, 1)
            XCTAssertEqual(policy, .prohibited)
        }
    }

    func testRestorationFailurePreservesOriginalErrorText() async throws {
        var policy = Policy.accessory
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                guard desired == .prohibited else { return false }
                policy = desired; return true
            }, operation: { throw OperationFailure() })
            XCTFail("Both failures must be surfaced")
        } catch let error as FinalCutApplyActivation.Failure {
            XCTAssertTrue(error.localizedDescription.contains("restore its previous activation policy"))
            XCTAssertTrue(error.localizedDescription.contains("Original Apply failure"))
        }
    }

    func testEntryFailureAlsoReportsAnUnrestorablePartialTransition() async throws {
        var policy = Policy.accessory
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                if desired == .prohibited { policy = desired }
                return false
            }, operation: {
                XCTFail("Apply cannot run after entry failure")
                return 0
            })
            XCTFail("Entry and restoration failures must escape")
        } catch let error as FinalCutApplyActivation.Failure {
            XCTAssertTrue(error.localizedDescription.contains("Apply did not start"))
            XCTAssertTrue(error.localizedDescription.contains("could not be restored"))
        }
    }

    func testRestorationReadbackMustMatchEvenWhenSetterReportsSuccess() async throws {
        var policy = Policy.accessory
        do {
            let _: Int = try await FinalCutApplyActivation.run(readPolicy: { policy }, setPolicy: { desired in
                if desired == .prohibited { policy = desired }
                return true
            }, operation: { 42 })
            XCTFail("A false successful restoration cannot hide prohibited policy")
        } catch let error as FinalCutApplyActivation.Failure {
            XCTAssertTrue(error.localizedDescription.contains("restore its previous activation policy"))
        }
    }
}
