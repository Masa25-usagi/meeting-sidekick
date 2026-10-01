import Foundation
import MeetingServices

/// Exercise real pipes with a local deterministic server: no API calls or account settings.
@MainActor
struct CodexBackendRegressionChecks {
    func testSilentServerTimeoutDoesNotRetryOrFallback() async throws {
        try await withServer(mode: "silent") { backend, fixture, fallback in
            let began = Date()
            do {
                _ = try await backend.generate(CodexRequest(prompt: "timeout", timeoutSeconds: 0.6))
                report(false, "silent pipe must time out", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .timeout) }
            expectLessThanOrEqual(Date().timeIntervalSince(began), 1.5)
            let requests = await fallback.requestCount
            expectEqual(requests, 0)
            // Cold interpreter startup may consume this deliberately short budget
            // before the fixture logs; neither case may start a retry.
            expectLessThanOrEqual(fixture.logLines.filter { $0 == "LAUNCH" }.count, 1)
        }
    }

    func testBlockedInputPipeHonorsTimeout() async throws {
        try await withServer(mode: "blocked-stdin") { backend, _, fallback in
            let began = Date()
            do {
                _ = try await backend.generate(CodexRequest(prompt: String(repeating: "x", count: 1_000_000), timeoutSeconds: 0.5))
                report(false, "a child that stopped reading must not block the writer", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .timeout) }
            expectLessThanOrEqual(Date().timeIntervalSince(began), 1.5)
            let requests = await fallback.requestCount
            expectEqual(requests, 0)
        }
    }

    func testActiveCancellationStopsPipeWaitAndAllowsNextTurn() async throws {
        try await withServer(mode: "normal") { backend, fixture, fallback in
            let pending = Task { try await backend.generate(CodexRequest(prompt: "silent-turn", timeoutSeconds: 5)) }
            try await fixture.waitForLog("TURN silent-turn")
            let began = Date()
            pending.cancel()
            do {
                _ = try await pending.value
                report(false, "cancelled active turn must not return a result", file: #filePath, line: #line)
            } catch is CancellationError {} catch {
                report(false, "active cancellation changed into \(error)", file: #filePath, line: #line)
            }
            expectLessThanOrEqual(Date().timeIntervalSince(began), 1)
            let requests = await fallback.requestCount
            expectEqual(requests, 0)
            let result = try await backend.generate(CodexRequest(prompt: "after-cancel", timeoutSeconds: 2))
            expectEqual(result.text, "OK after-cancel")
            expectEqual(fixture.logLines.filter { $0 == "TURN silent-turn" }.count, 1)
        }
    }

    func testQueuedCancellationAndTimeoutDoNotStopOwner() async throws {
        try await withServer(mode: "normal") { backend, fixture, _ in
            let owner = Task { try await backend.generate(CodexRequest(prompt: "slow-turn", timeoutSeconds: 3)) }
            try await fixture.waitForLog("TURN slow-turn")
            let cancelled = Task { try await backend.generate(CodexRequest(prompt: "queued-cancel", timeoutSeconds: 2)) }
            try await Task.sleep(nanoseconds: 20_000_000)
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                report(false, "queued cancel must fail", file: #filePath, line: #line)
            } catch is CancellationError {}
            let began = Date()
            do {
                _ = try await backend.generate(CodexRequest(prompt: "queued-timeout", timeoutSeconds: 0.08))
                report(false, "queue wait consumes the deadline", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .timeout) }
            expectLessThanOrEqual(Date().timeIntervalSince(began), 0.5)
            let result = try await owner.value
            expectEqual(result.text, "OK slow-turn")
            expectFalse(fixture.logLines.contains("TURN queued-cancel"))
            expectFalse(fixture.logLines.contains("TURN queued-timeout"))
        }
    }

    func testSearchEventsAreScopedAndURLsComeFromHostResults() async throws {
        try await withServer(mode: "search") { backend, _, _ in
            let result = try await backend.generate(CodexRequest(prompt: "scoped", enableSearch: true, timeoutSeconds: 3))
            expectEqual(result.text, "OK scoped")
            expectEqual(result.webSearchUsed, true)
            expectEqual(result.webSearchSources, ["https://example.com/verified"])
            let noSearch = try await backend.generate(CodexRequest(prompt: "no-search", timeoutSeconds: 3))
            expectEqual(noSearch.webSearchUsed, false)
            expectEqual(noSearch.webSearchSources, [])
        }
    }

    func testMissingSearchTelemetryRemainsUnknown() async throws {
        try await withServer(mode: "missing-items") { backend, _, _ in
            let result = try await backend.generate(CodexRequest(prompt: "unknown", enableSearch: true, timeoutSeconds: 3))
            expectEqual(result.text, "OK unknown")
            expectEqual(result.webSearchUsed, nil)
            expectEqual(result.webSearchSources, [])
        }
    }

    func testStaleTerminationDoesNotKillNewGeneration() async throws {
        try await withServer(mode: "normal") { backend, fixture, _ in
            _ = try await backend.generate(CodexRequest(prompt: "first", timeoutSeconds: 3))
            let oldGeneration = backend.currentGeneration
            let newTurn = Task { try await backend.generate(CodexRequest(prompt: "slow-turn", timeoutSeconds: 3)) }
            try await fixture.waitForLog("TURN slow-turn")
            await backend.terminate(targetGeneration: oldGeneration)
            let result = try await newTurn.value
            expectEqual(result.text, "OK slow-turn")
            // Current-generation termination must unblock an active pipe wait even
            // when the caller itself has not cancelled its Task.
            let active = Task { try await backend.generate(CodexRequest(prompt: "silent-turn", timeoutSeconds: 5)) }
            try await fixture.waitForLog("TURN silent-turn")
            await backend.terminate(targetGeneration: backend.currentGeneration)
            do {
                _ = try await active.value
                report(false, "targeted termination must invalidate the result", file: #filePath, line: #line)
            } catch is CancellationError {}
        }
    }

    func testSemanticErrorsDoNotRetryOrEscapeModelPolicy() async throws {
        try await withServer(mode: "unavailable-model") { backend, fixture, fallback in
            do {
                _ = try await backend.generate(CodexRequest(prompt: "model-test", model: "gpt-6-sol", timeoutSeconds: 3))
                report(false, "missing Sol must fail", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .modelUnavailable("gpt-6-sol")) }
            let requests = await fallback.requestCount
            expectEqual(requests, 0)
            expectEqual(fixture.logLines.filter { $0 == "LAUNCH" }.count, 1)
        }
        try await withServer(mode: "failed-turn") { backend, fixture, fallback in
            do {
                _ = try await backend.generate(CodexRequest(prompt: "failure-test", timeoutSeconds: 3))
                report(false, "turn failure must propagate", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .turnFailed("quota exhausted")) }
            let requests = await fallback.requestCount
            expectEqual(requests, 0)
            expectEqual(fixture.logLines.filter { $0 == "TURN failure-test" }.count, 1)
        }
    }

    func testOneDeadlineCoversStartupAndTurn() async throws {
        try await withServer(mode: "staged-delay") { backend, _, _ in
            let began = Date()
            do {
                _ = try await backend.generate(CodexRequest(prompt: "budget", timeoutSeconds: 0.6))
                report(false, "startup must consume the total deadline", file: #filePath, line: #line)
            } catch let error as CodexAppServerError { expectEqual(error, .timeout) }
            expectLessThanOrEqual(Date().timeIntervalSince(began), 1.3)
        }
    }

    private func withServer(
        mode: String,
        body: (CodexAppServerBackend, BackendServerFixture, CountingFallback) async throws -> Void
    ) async throws {
        let fixture = try BackendServerFixture(mode: mode)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fallback = CountingFallback()
        let backend = CodexAppServerBackend(executablePath: fixture.executable.path,
            defaultWorkingDirectory: fixture.directory.path, fallbackBackend: fallback)
        do { try await body(backend, fixture, fallback) }
        catch { await backend.terminate(); throw error }
        await backend.terminate()
    }
}

private actor CountingFallback: CodexBackend {
    private(set) var requestCount = 0
    func generate(_ request: CodexRequest) async throws -> CodexGenerationResult {
        requestCount += 1
        return CodexGenerationResult(text: "fallback", backend: "exec", requestedModel: "gpt-6-sol",
            resolvedModel: "gpt-6-sol", reasoningEffort: "low", webSearchMode: "disabled")
    }
}

private struct BackendServerFixture {
    let directory: URL
    let executable: URL
    let log: URL
    var logLines: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
    }
    func waitForLog(_ marker: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if logLines.contains(marker) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "BackendServerFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Fixture did not reach \(marker)"])
    }
    init(mode: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("mock-codex")
        log = directory.appendingPathComponent("events.log")
        let source = #"""
#!/usr/bin/python3
import json, os, sys, time
mode = "__MODE__"
logfile = os.path.join(os.path.dirname(__file__), "events.log")
def log(text):
    with open(logfile, "a") as f: f.write(text + "\n")
def send(value):
    sys.stdout.write(json.dumps(value) + "\n"); sys.stdout.flush()
def reply(req, value): send({"id": req["id"], "result": value})
def item(thread, turn, value):
    send({"method": "item/completed", "params": {"threadId": thread, "turnId": turn, "item": value}})
def search(url):
    return {"type": "webSearch", "id": "search", "query": "fixture", "results": [{"entries": [{"url": url}]}]}
log("LAUNCH")
for line in sys.stdin:
    req = json.loads(line); method = req.get("method"); params = req.get("params", {})
    if method == "initialize":
        if mode == "silent": time.sleep(30)
        if mode == "staged-delay": time.sleep(0.15)
        reply(req, {})
    elif method == "model/list":
        if mode == "staged-delay": time.sleep(0.15)
        model = "gpt-6-astra" if mode == "unavailable-model" else "gpt-6-sol"
        reply(req, {"data": [{"id": model, "model": model}]})
    elif method == "thread/start":
        if mode == "staged-delay": time.sleep(0.15)
        reply(req, {"thread": {"id": "thread-" + str(req["id"])}})
        if mode == "blocked-stdin": time.sleep(30)
    elif method == "turn/start":
        text = params["input"][0]["text"]; thread = params["threadId"]; turn = "turn-" + str(req["id"])
        log("TURN " + text)
        if text == "silent-turn": time.sleep(30)
        if text == "slow-turn": time.sleep(0.5)
        if mode == "staged-delay": time.sleep(0.4)
        if mode == "search":
            # Before the response: must be scoped again once the actual turnId is known.
            item(thread, "stale-turn", search("https://example.com/stale-before"))
        reply(req, {"turn": {"id": turn}})
        if mode == "search":
            item("other-thread", turn, search("https://example.com/other-thread"))
            item(thread, "stale-turn", search("https://example.com/stale-after"))
            send({"method": "turn/completed", "params": {"threadId": thread,
                "turn": {"id": "stale-turn", "status": "completed", "items": [{"type": "agentMessage", "text": "WRONG"}]}}})
            if text == "scoped":
                item(thread, turn, search("https://example.com/verified"))
                item(thread, turn, search("file:///private/secret"))
        message = {"type": "agentMessage", "phase": "finalAnswer", "text": "OK " + text}
        item(thread, turn, message)
        completed = {"id": turn, "status": "completed", "items": [message]}
        if mode == "missing-items": del completed["items"]
        if mode == "failed-turn": completed.update({"status": "failed", "error": {"message": "quota exhausted"}})
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": completed}})
"""#.replacingOccurrences(of: "__MODE__", with: mode)
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
}
