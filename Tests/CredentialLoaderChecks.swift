import Foundation
import MeetingCore

@MainActor
func runCredentialLoaderChecks() async throws {
    let loaded = await CredentialLoader.load(timeout: 1) { "test-\($0)" }
    expectEqual(loaded, ["gemini": "test-gemini", "openai": "test-openai", "jev": "test-jev"])

    // A blocked filesystem/keychain call must not keep its caller waiting.
    let stalled = DispatchSemaphore(value: 0)
    let start = Date()
    let timedOut = await CredentialLoader.load(timeout: 0.03) { _ in
        stalled.wait()
        return "late"
    }
    expectTrue(timedOut == nil)
    expectLessThanOrEqual(Date().timeIntervalSince(start), 1.0)
    stalled.signal()

    let cancelledRead = DispatchSemaphore(value: 0)
    let task = Task { await CredentialLoader.load(timeout: 5) { _ in
        cancelledRead.wait()
        return "late"
    } }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    let cancelled = await task.value
    expectTrue(cancelled == nil)
    cancelledRead.signal()
    // Let the late completions execute; neither may resume a caller twice.
    try await Task.sleep(for: .milliseconds(30))
}
