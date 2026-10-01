import Foundation
import Speech
@testable import MeetingServices
import MeetingCore

@MainActor
final class ProtocolTests {
    func testGeminiDoesNotPlaceKeyInURL() throws {
        let request = try GeminiLiveWire.request(apiKey: "test-secret")
        expectFalse(request.url!.absoluteString.contains("test-secret"))
        expectEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-secret")
    }
    func testSetupUsesAudioAndBoundedCompression() throws {
        let data = try GeminiLiveWire.setup(model: "gemini-3.8-live", instructions: "test")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let setup = json["setup"] as! [String: Any]
        expectNotNil(setup["contextWindowCompression"])
        expectEqual(setup["model"] as? String, "models/gemini-3.8-live")
        expectThrows(try GeminiLiveWire.setup(model: "../../bad", instructions: ""))
    }
    func testInterruptionDropsAudio() throws {
        let json: [String: Any] = ["serverContent": ["interrupted": true, "modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": "AAA="]]]]]]
        let event = try GeminiLiveWire.parse(JSONSerialization.data(withJSONObject: json))
        expectTrue(event.interrupted); expectTrue(event.audio.isEmpty)
    }
    func testAudioAndImageValidation() throws {
        expectThrows(try GeminiLiveWire.audio(Data([1])))
        expectThrows(try GeminiLiveWire.frame(Data([1, 2, 3])))
        expectNoThrow(try GeminiLiveWire.audio(Data([0, 0])))
        let text = try JSONSerialization.jsonObject(with: GeminiLiveWire.text("image question")) as! [String: Any]
        expectNotNil(text["realtimeInput"])
        expectTrue(text["clientContent"] == nil)
    }
    func testJevStrictScores() throws {
        let good = ["answers": Dictionary(uniqueKeysWithValues: ["wake", "idea", "relevant", "negated", "modify", "stop", "speak"].map { ($0, ["type": "noul", "noul": $0 == "negated" ? 0.1 : 0.8] as [String: Any]) })]
        let parsed = try JevWire.parse(JSONSerialization.data(withJSONObject: good), topic: "hello")
        expectEqual(parsed.buildScore, 0.8)
        expectThrows(try JevWire.parse(Data("{\"answers\":{}}".utf8), topic: ""))
    }
    func testGeminiSetupIncludesPrototypeTool() throws {
        let data = try GeminiLiveWire.setup(model: "gemini-3.8-live", instructions: "test")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let setup = json["setup"] as! [String: Any]
        let tools = setup["tools"] as! [[String: Any]]
        let funcs = tools.first?["functionDeclarations"] as! [[String: Any]]
        expectEqual(funcs.first?["name"] as? String, "build_prototype")
    }
    func testGeminiParsesToolCallAndGeneratesToolResponse() throws {
        let toolJson: [String: Any] = [
            "toolCall": [
                "functionCalls": [
                    ["name": "build_prototype", "args": ["topic": "議事録ツール"], "id": "call_123"]
                ]
            ]
        ]
        let event = try GeminiLiveWire.parse(JSONSerialization.data(withJSONObject: toolJson))
        expectEqual(event.toolCalls.count, 1)
        expectEqual(event.toolCalls.first?.name, "build_prototype")
        expectEqual(event.toolCalls.first?.args["topic"] as? String, "議事録ツール")
        let response = try GeminiLiveWire.toolResponse(callId: "call_123", name: "build_prototype", response: ["status": "ok"])
        let parsedResp = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        expectNotNil(parsedResp["toolResponse"])
    }
    func testOpenAIRealtimeWireRequestAndHeaders() throws {
        let request = try OpenAIRealtimeWire.request(apiKey: "openai-secret", model: "gpt-4o-realtime-preview")
        expectFalse(request.url!.absoluteString.contains("openai-secret"))
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        expectEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
    }
    func testOpenAIRealtimeSessionUpdateAndEvents() throws {
        let sessionData = try OpenAIRealtimeWire.sessionUpdate(instructions: "会議アシスタント")
        let sessionJson = try JSONSerialization.jsonObject(with: sessionData) as! [String: Any]
        let session = sessionJson["session"] as! [String: Any]
        let tools = session["tools"] as! [[String: Any]]
        expectEqual(tools.first?["name"] as? String, "build_prototype")

        let audioDeltaJson: [String: Any] = ["type": "response.audio.delta", "delta": "AAAA"]
        let audioEvent = try OpenAIRealtimeWire.parse(JSONSerialization.data(withJSONObject: audioDeltaJson))
        expectEqual(audioEvent.audio.count, 1)

        let toolJson: [String: Any] = [
            "type": "response.function_call_arguments.done",
            "name": "build_prototype",
            "call_id": "call_abc",
            "arguments": "{\"topic\":\"タスク管理アプリ\"}"
        ]
        let toolEvent = try OpenAIRealtimeWire.parse(JSONSerialization.data(withJSONObject: toolJson))
        expectEqual(toolEvent.toolCalls.count, 1)
        expectEqual(toolEvent.toolCalls.first?.name, "build_prototype")
        expectEqual(toolEvent.toolCalls.first?.args["topic"] as? String, "タスク管理アプリ")
    }

    func testContextIngestorParsesSynthesizedRules() throws {
        let ingestor = ContextIngestor()
        let sampleJson = """
        ```json
        {
          "objective": "日常のライフログからアプリを作る",
          "nickname": "パートナー",
          "persona": "冷静沈着なテックリード",
          "speakCriteria": ["既存の機能と重複するとき", "スケジュールが非現実的なとき"],
          "buildCriteria": ["具体的なUIレイアウトが決まったとき"],
          "doNotBuildCriteria": ["課金APIの実装"],
          "projectSummary": "ライフログから自動でプロトタイプを作るシステム"
        }
        ```
        """
        let rules = try ingestor.parseSynthesizedRules(jsonText: sampleJson, defaultObjective: "テスト", defaultNickname: "相棒")
        expectEqual(rules.objective, "日常のライフログからアプリを作る")
        expectEqual(rules.nickname, "パートナー")
        expectEqual(rules.persona, "冷静沈着なテックリード")
        expectEqual(rules.speakCriteria.count, 2)
        expectEqual(rules.buildCriteria.count, 1)
        expectEqual(rules.doNotBuildCriteria.count, 1)
        expectTrue(rules.formattedMarkdown.contains("### 🎭 役割・キャラクター"))
    }

    /// P1-4: 不正なAI応答（認証エラーや空JSONなど）が作り物の基準で成功に化けないことを検証
    func testStrictRuleValidationRejectsInvalidOutput() throws {
        let ingestor = ContextIngestor()

        // 1. 認証エラー文字列
        expectThrows(try ingestor.parseSynthesizedRules(
            jsonText: "Authentication required. Please login.",
            defaultObjective: "テスト",
            defaultNickname: "相棒"
        ))

        // 2. 空のJSONオブジェクト
        expectThrows(try ingestor.parseSynthesizedRules(
            jsonText: "{}",
            defaultObjective: "テスト",
            defaultNickname: "相棒"
        ))

        // 3. 基準が欠落した不完全なJSON
        let incompleteJson = """
        {
          "objective": "テスト目的",
          "speakCriteria": []
        }
        """
        expectThrows(try ingestor.parseSynthesizedRules(
            jsonText: incompleteJson,
            defaultObjective: "テスト",
            defaultNickname: "相棒"
        ))
    }

    /// P1-7: 16kHz PCM16から24kHz PCM16へのリサンプラーが3:2の比率で正確に変換されることを検証
    func testOpenAIResamplerRatioAndContinuity() throws {
        // 1秒分の16kHz PCM16サンプル（16,000サンプル = 32,000バイト）
        let sampleCount = 16_000
        var inputSamples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            inputSamples[i] = Int16(clamping: Int32(sin(Double(i) * 0.1) * 10000))
        }
        var inputData = Data(capacity: sampleCount * 2)
        inputSamples.withUnsafeBytes { inputData.append(contentsOf: $0) }

        let resampled = OpenAIRealtimeWire.resample16kTo24k(inputData)

        // 16,000サンプルの入力に対して、24,000サンプル（48,000バイト）が出力されること
        let expectedSampleCount = 24_000
        let outputSampleCount = resampled.count / 2
        expectEqual(outputSampleCount, expectedSampleCount)
        expectEqual(resampled.count, expectedSampleCount * 2)
    }

    /// P1-7: 複数チャンクの分割ストリーミング投入（奇数バイト境界含む）と一括変換の出力が完全一致することを検証
    func testPCM16StreamingResamplerChunkContinuity() throws {
        // 1,600サンプル（3,200バイト）の連続音声を生成
        let sampleCount = 1_600
        var inputSamples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            inputSamples[i] = Int16(clamping: Int32(cos(Double(i) * 0.05) * 8000))
        }
        var allData = Data(capacity: sampleCount * 2)
        inputSamples.withUnsafeBytes { allData.append(contentsOf: $0) }

        // パターンA: 一括投入
        let resamplerA = PCM16StreamingResampler()
        var outputA = resamplerA.process(allData)
        outputA.append(resamplerA.finish())

        // パターンB: 様々なサイズのチャンクに分割して連続投入（奇数バイト含む）
        let resamplerB = PCM16StreamingResampler()
        var outputB = Data()
        let chunkSizes = [13, 27, 4, 100, 255, 301, 50, 10, 200, 77]
        var offset = 0
        var sizeIndex = 0
        while offset < allData.count {
            let chunkSize = min(chunkSizes[sizeIndex % chunkSizes.count], allData.count - offset)
            let sub = allData.subdata(in: offset..<(offset + chunkSize))
            outputB.append(resamplerB.process(sub))
            offset += chunkSize
            sizeIndex += 1
        }
        outputB.append(resamplerB.finish())

        // バイト数およびバイト内容が1バイトの狂いもなく完全一致することを検証
        expectEqual(outputA.count, outputB.count)
        expectEqual(outputA, outputB)
    }

    /// P1-3: 大量stderr（2MB）を出力するプロセスでも、並行非同期ドレインによりデッドロックせず完了することを検証
    func testCLIDrainsLargeStderrWithoutDeadlock() async throws {
        let client = CLITextClient()
        // /bin/sh を使って stderr に大量データ（1MB以上）を出力するプロセス
        let script = "yes '大量エラーログ出力テスト' | head -n 40000 1>&2"
        let result = try await client.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            timeoutSeconds: 5
        )
        // デッドロックせず完了し、stderrが安全に読み取られること
        expectEqual(result.exitCode, 0)
        expectGreaterThan(result.stderr.count, 1000)
    }

    /// P1-3: タイムアウト機能が働き、長時間ハングするプロセスが安全にterminateされることを検証
    func testCLITimeout() async throws {
        let client = CLITextClient()
        var didCatchTimeout = false
        do {
            _ = try await client.runProcess(
                executablePath: "/bin/sleep",
                arguments: ["10"],
                timeoutSeconds: 0.3
            )
        } catch let error as CLIError {
            if error == .timeout {
                didCatchTimeout = true
            }
        } catch {}
        expectTrue(didCatchTimeout)
    }

    func testContextIngestorScansProjectFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reqFile = tempDir.appendingPathComponent("REQUEST.md")
        try "議事録を要約してタスクを自動抽出するツールを作る".write(to: reqFile, atomically: true, encoding: .utf8)

        let ingestor = ContextIngestor()
        let context = ingestor.scanDirectoryContext(at: tempDir)
        expectTrue(context.projectSummary.contains("[REQUEST.md]"))
        expectTrue(context.combinedDescription.contains("議事録を要約して"))
    }

    func testCLIExecutableResolution() throws {
        let client = CLITextClient()
        let codex = client.resolveExecutable("codex")
        expectTrue(!codex.isEmpty)
        let agy = client.resolveExecutable("agy")
        expectTrue(!agy.isEmpty)
        let grok = client.resolveExecutable("grok")
        expectTrue(!grok.isEmpty)
    }

    /// P1-2 & P2-8: MobileLogReceiver の認証チェック（PIN秘匿、PIN認証・トークン発行、試行制限ロックアウト、無認証拒絶401）の検証
    @MainActor
    func testMobileLogReceiverAuthentication() async throws {
        let receiver = MobileLogReceiver(port: 9876)
        receiver.start()
        defer { receiver.stop() }

        // リスナーの起動待ち
        try await Task.sleep(nanoseconds: 100_000_000)

        // 1. GET / のHTMLレスポンスに秘密PINやセッショントークンが含まれていないこと
        let indexUrl = URL(string: "http://127.0.0.1:9876/")!
        let (indexData, _) = try await URLSession.shared.data(from: indexUrl)
        let indexHtml = String(data: indexData, encoding: .utf8) ?? ""
        expectFalse(indexHtml.contains(receiver.pairingToken))

        // 2. 無認証でのPOSTリクエスト -> 401 Unauthorized が返ること
        let logUrl = URL(string: "http://127.0.0.1:9876/api/log")!
        var unauthReq = URLRequest(url: logUrl)
        unauthReq.httpMethod = "POST"
        unauthReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthReq.httpBody = Data("{\"text\":\"無認証ログ\"}".utf8)

        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        if let http = unauthResp as? HTTPURLResponse {
            expectEqual(http.statusCode, 401)
        } else {
            report(false, "expected HTTPURLResponse", file: #filePath, line: #line)
        }

        // 3. 不正なPINで /api/pair を5回連続送信 -> 5回目でロックアウト（403 Forbidden）されること
        let pairUrl = URL(string: "http://127.0.0.1:9876/api/pair")!
        for i in 1...5 {
            var wrongPairReq = URLRequest(url: pairUrl)
            wrongPairReq.httpMethod = "POST"
            wrongPairReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            wrongPairReq.httpBody = Data("{\"pin\":\"000000\"}".utf8)
            let (_, pairResp) = try await URLSession.shared.data(for: wrongPairReq)
            if let http = pairResp as? HTTPURLResponse {
                if i < 5 {
                    expectEqual(http.statusCode, 401)
                } else {
                    expectEqual(http.statusCode, 403)
                }
            }
        }

        // 4. 正しいPINを再生成してリセット後、/api/pair でセッショントークンを取得
        receiver.regenerateToken() // ロック解除 & 新PIN
        var validPairReq = URLRequest(url: pairUrl)
        validPairReq.httpMethod = "POST"
        validPairReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        validPairReq.httpBody = Data("{\"pin\":\"\(receiver.pairingToken)\"}".utf8)
        let (pairData, pairResp) = try await URLSession.shared.data(for: validPairReq)
        var sessionToken = ""
        if let http = pairResp as? HTTPURLResponse {
            expectEqual(http.statusCode, 200)
            if let json = try? JSONSerialization.jsonObject(with: pairData) as? [String: Any],
               let token = json["token"] as? String {
                sessionToken = token
                expectFalse(sessionToken.isEmpty)
            } else {
                report(false, "expected token in pair response", file: #filePath, line: #line)
            }
        }

        // 5. 発行されたセッショントークンでPOST /api/log -> 200 OK になり、ログが記録されること
        var receivedText: String? = nil
        receiver.onLogReceived = { receivedText = $0 }

        var authReq = URLRequest(url: logUrl)
        authReq.httpMethod = "POST"
        authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authReq.setValue(sessionToken, forHTTPHeaderField: "X-Meeting-Token")
        authReq.httpBody = Data("{\"text\":\"認証済み胸ポケット音声ログ\"}".utf8)

        let (_, authResp) = try await URLSession.shared.data(for: authReq)
        if let http = authResp as? HTTPURLResponse {
            expectEqual(http.statusCode, 200)
            expectEqual(receivedText, "認証済み胸ポケット音声ログ")
            expectTrue(receiver.receivedLogs.contains("認証済み胸ポケット音声ログ"))
        } else {
            report(false, "expected HTTPURLResponse", file: #filePath, line: #line)
        }

        // 6. 指摘事項1: pairing PINそのものを X-Meeting-Token として渡しても 401 Unauthorized で拒絶されること
        var pinAsTokenReq = URLRequest(url: logUrl)
        pinAsTokenReq.httpMethod = "POST"
        pinAsTokenReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pinAsTokenReq.setValue(receiver.pairingToken, forHTTPHeaderField: "X-Meeting-Token")
        pinAsTokenReq.httpBody = Data("{\"text\":\"PINによる直接送信の試み\"}".utf8)
        let (_, pinResp) = try await URLSession.shared.data(for: pinAsTokenReq)
        if let http = pinResp as? HTTPURLResponse {
            expectEqual(http.statusCode, 401)
        }

        // 7. 指摘事項1: PIN再生成（regenerateToken）時に既存のセッショントークンがすべて失効し、401 Unauthorized になること
        receiver.regenerateToken()
        let (_, revokedResp) = try await URLSession.shared.data(for: authReq)
        if let http = revokedResp as? HTTPURLResponse {
            expectEqual(http.statusCode, 401)
        }
    }

    /// 指摘事項3: JEV の summary 構造化スコアをパースし、Judgment.shouldSummarize が正しくトリガーされること
    func testJevSummaryScoreAndTrigger() throws {
        let jsonWithSummary: [String: Any] = [
            "answers": [
                "wake": ["type": "noul", "noul": 0.1],
                "idea": ["type": "noul", "noul": 0.1],
                "relevant": ["type": "noul", "noul": 0.2],
                "negated": ["type": "noul", "noul": 0.0],
                "modify": ["type": "noul", "noul": 0.0],
                "stop": ["type": "noul", "noul": 0.0],
                "speak": ["type": "noul", "noul": 0.1],
                "summary": ["type": "noul", "noul": 0.85],
                "decide_build": ["type": "noul", "noul": 0.1]
            ]
        ]
        let judgment = try JevWire.parse(JSONSerialization.data(withJSONObject: jsonWithSummary), topic: "これまでの議論のまとめ")
        expectEqual(judgment.summaryScore, 0.85)
        expectTrue(judgment.shouldSummarize)

        // summaryが低い場合は shouldSummarize == false
        let jsonWithoutSummary: [String: Any] = [
            "answers": [
                "wake": ["type": "noul", "noul": 0.1],
                "idea": ["type": "noul", "noul": 0.1],
                "relevant": ["type": "noul", "noul": 0.2],
                "negated": ["type": "noul", "noul": 0.0],
                "modify": ["type": "noul", "noul": 0.0],
                "stop": ["type": "noul", "noul": 0.0],
                "speak": ["type": "noul", "noul": 0.1],
                "summary": ["type": "noul", "noul": 0.3],
                "decide_build": ["type": "noul", "noul": 0.1]
            ]
        ]
        let judgmentLow = try JevWire.parse(JSONSerialization.data(withJSONObject: jsonWithoutSummary), topic: "通常の発言")
        expectEqual(judgmentLow.summaryScore, 0.3)
        expectFalse(judgmentLow.shouldSummarize)
    }

    /// 指摘事項2-A: 遅延JEV結果破棄の自動テスト
    /// 会議停止・リセット後に遅延JEVが返ってきても、guard token == sessionID, currentEpoch == workEpoch により完全破棄され
    /// 新規ジョブやアクションが発火しないことを assert
    func testDelayedJevResponseDiscardedOnSessionResetOrStopWork() async throws {
        let delayedJudge = DelayedJevJudge()
        var settings = AppSettings()
        settings.policy = MeetingPolicy(objective: "遅延テスト", autoBuild: true)
        settings.useJev = true
        settings.judgeEndpoint = "https://localhost"

        let runtime = MeetingRuntime(
            settings: settings,
            judge: delayedJudge,
            jevKeyOverride: "test-key"
        )
        runtime.running = true

        // 発言投入（遅延JEV判定開始: 200ms）
        let event = TranscriptEvent(text: "タスク管理アプリを作って", source: .meeting, isFinal: true)
        runtime.receive(event)

        // JEV応答が返る前（50ms後）に会議停止（stopWork / stopMeeting）
        try await Task.sleep(nanoseconds: 50_000_000)
        await runtime.stopMeeting()

        // JEV遅延時間（200ms）が経過するまで待機（計300ms）
        try await Task.sleep(nanoseconds: 300_000_000)

        // JEV呼び出しが行われたこと、しかし停止ガードによりジョブ生成やアクション発火が一切ないこと
        expectTrue(delayedJudge.evaluateCalled)
        expectTrue(runtime.jobs.isEmpty)
        expectTrue(runtime.lastDispatchedActions.isEmpty)
    }

    /// 指摘事項2-A: LiveProvider切替中の安全性の自動テスト
    /// 旧Providerと新Providerが存在する状態でProvider設定を切替。
    /// 旧Providerからの遅延コールバックが無視され、新Providerのみに送信されることを assert
    func testProviderSwitchSafety() async throws {
        let geminiSpy = TestLiveProviderSpy()
        let openaiSpy = TestLiveProviderSpy()

        var settings = AppSettings()
        settings.voiceProvider = "gemini"
        settings.liveModel = "gemini-3.8-live"
        settings.openaiModel = "gpt-4o-realtime-preview"

        let runtime = MeetingRuntime(
            settings: settings,
            geminiLive: geminiSpy,
            openaiLive: openaiSpy,
            geminiKeyOverride: "test-gemini-key",
            openaiKeyOverride: "test-openai-key"
        )
        runtime.running = true

        // 1. 初期プロバイダ（Gemini）で音声起動
        await runtime.wakeVoice(prompt: "Geminiへの呼びかけ")
        expectTrue(geminiSpy.connectCalled)
        expectEqual(geminiSpy.sentTexts, ["Geminiへの呼びかけ"])
        expectTrue(runtime.activeLiveProvider === geminiSpy)
        geminiSpy.onText?("Geminiの返答")
        expectEqual(runtime.reply, "Geminiの返答")

        // 2. プロバイダを OpenAI に切替えて音声起動
        runtime.settings.voiceProvider = "openai"
        await runtime.wakeVoice(prompt: "OpenAIへの呼びかけ")
        expectTrue(openaiSpy.connectCalled)
        expectEqual(openaiSpy.sentTexts, ["OpenAIへの呼びかけ"])
        expectTrue(runtime.activeLiveProvider === openaiSpy)

        // 旧Gemini側は切替時にdisconnectされていること
        expectTrue(geminiSpy.disconnectCalled)

        // 3. 切替後に旧Provider（Gemini）から遅延テキストコールバックを発火
        geminiSpy.onText?("旧Geminiからの遅延テキスト")
        // activeLiveProvider === provider ガードにより、replyに一切反映されず破棄されること
        expectEqual(runtime.reply, "") // wakeVoiceで初期化された後、旧コールバックは無視される

        // 4. 新OpenAIからのテキストコールバックは正常に反映されること
        openaiSpy.onText?("新OpenAIからの返答")
        expectEqual(runtime.reply, "新OpenAIからの返答")

        // 5. 再度旧Geminiからコールバックが来ても無視されること
        geminiSpy.onText?("再び旧Geminiからの遅延テキスト")
        expectEqual(runtime.reply, "新OpenAIからの返答")

        // 6. 新しい送信が旧Geminiへ流れていないこと（sentTextsが切替前の1件のみのまま）
        expectEqual(geminiSpy.sentTexts.count, 1)
    }

    /// JEV の term_research 構造化スコアをパースし、Judgment.termResearchScore に正しく反映されること
    func testJevTermResearchScoreParsing() throws {
        let jsonWithTermResearch: [String: Any] = [
            "answers": [
                "wake": ["type": "noul", "noul": 0.1],
                "idea": ["type": "noul", "noul": 0.1],
                "relevant": ["type": "noul", "noul": 0.2],
                "negated": ["type": "noul", "noul": 0.0],
                "modify": ["type": "noul", "noul": 0.0],
                "stop": ["type": "noul", "noul": 0.0],
                "speak": ["type": "noul", "noul": 0.1],
                "term_research": ["type": "noul", "noul": 0.88],
            ]
        ]
        let parsed = try JevWire.parse(JSONSerialization.data(withJSONObject: jsonWithTermResearch), topic: "用語テスト")
        expectEqual(parsed.termResearchScore, 0.88)

        // term_research が存在しないレガシーJSONでも 0.0 として安全にパースされること (fail-safe)
        let jsonWithoutTermResearch: [String: Any] = [
            "answers": [
                "wake": ["type": "noul", "noul": 0.1],
                "idea": ["type": "noul", "noul": 0.1],
                "relevant": ["type": "noul", "noul": 0.2],
                "negated": ["type": "noul", "noul": 0.0],
                "modify": ["type": "noul", "noul": 0.0],
                "stop": ["type": "noul", "noul": 0.0],
                "speak": ["type": "noul", "noul": 0.1],
            ]
        ]
        let parsedLegacy = try JevWire.parse(JSONSerialization.data(withJSONObject: jsonWithoutTermResearch), topic: "レガシーテスト")
        expectEqual(parsedLegacy.termResearchScore, 0.0)
    }

    /// 構造化JSON出力から専門用語抽出（sources含む）が正しく動作すること
    func testTerminologyExtraction() {
        // 1. sources付きの正常なJSONブロック
        let validJson = """
        思考メモを出力しました。
        ```json
        {
          "term": "OCuLink",
          "summary": "高速外付けPCIe接続規格",
          "detail": "外部GPU接続などに用いられる規格です。",
          "sources": [
            {"title": "PCI-SIG Official", "url": "https://pcisig.com/specifications/oculink"},
            {"title": "", "url": "https://en.wikipedia.org/wiki/OCuLink"}
          ]
        }
        ```
        """
        let extracted = TerminologyExtraction.parse(from: validJson)
        expectNotNil(extracted)
        expectEqual(extracted?.term, "OCuLink")
        expectEqual(extracted?.summary, "高速外付けPCIe接続規格")
        expectEqual(extracted?.sources.count, 2)
        expectEqual(extracted?.sources.first?.title, "PCI-SIG Official")
        expectEqual(extracted?.sources.first?.url, "https://pcisig.com/specifications/oculink")
        // 空タイトルの場合はURLがフォールバックされること
        expectEqual(extracted?.sources.last?.title, "https://en.wikipedia.org/wiki/OCuLink")

        // 2. sources無しの正常なJSONブロック（安全なフォールバック）
        let noSourcesJson = """
        ```json
        {
          "term": "eGPU",
          "summary": "外付けグラフィックプロセッサ",
          "detail": "ThunderboltやOCuLinkで接続します。"
        }
        ```
        """
        let extractedNoSources = TerminologyExtraction.parse(from: noSourcesJson)
        expectNotNil(extractedNoSources)
        expectEqual(extractedNoSources?.term, "eGPU")
        expectTrue(extractedNoSources?.sources.isEmpty == true)

        // 3. 空の用語名
        let emptyTermJson = """
        {
          "term": "",
          "summary": "用語なし",
          "detail": ""
        }
        """
        expectTrue(TerminologyExtraction.parse(from: emptyTermJson) == nil)

        // 4. 不正なJSON
        let invalidJson = "用語はありませんでした。"
        expectTrue(TerminologyExtraction.parse(from: invalidJson) == nil)
    }

    /// MeetingRuntime の用語調査キャッシュ・同一用語での再実行抑止・fail-silent 挙動の検証
    func testMeetingRuntimeResearchDeduplicationAndFailSilent() async throws {
        let mockResearcher = MockTerminologyResearchClient()
        let note = ResearchNote(
            term: "OCuLink",
            summary: "PCIe外付け規格",
            detail: "詳細解説",
            sourceEngine: "codex (gpt-5.6-sol)",
            evidenceText: "OCuLinkについて調べましょう",
            sources: [ResearchSource(title: "PCI-SIG", url: "https://pcisig.com")]
        )
        await mockResearcher.setStubbedResult(.success(note))

        let runtime = MeetingRuntime(researchClient: mockResearcher)
        runtime.running = true

        // 1. 初回の用語調査実行
        runtime.startTerminologyResearch(evidenceText: "OCuLinkについて調べましょう", evidenceID: "ev-1")
        await runtime.waitForIdle()

        expectEqual(runtime.researchNotes.count, 1)
        expectEqual(runtime.researchNotes.first?.term, "OCuLink")
        expectEqual(runtime.researchNotes.first?.sources.count, 1)
        expectTrue(runtime.researchedTerms.contains("oculink"))
        let count1 = await mockResearcher.callCount
        expectEqual(count1, 1)

        // 2. 同一用語の2回目の実行（発話が別でも同一用語が含まれる場合はTask自体を起動しない）
        runtime.startTerminologyResearch(evidenceText: "OCuLinkの速度はどうですか？", evidenceID: "ev-2")
        await runtime.waitForIdle()

        // 重要: 2回目はTask自体が起動せず、mockResearcher.callCount は 1 のまま維持されること！
        let count2 = await mockResearcher.callCount
        expectEqual(count2, 1)
        expectEqual(runtime.researchNotes.count, 1)

        // 3. Fail-silent の検証（エラー発生時に例外やUIエラーが出ず静かに無視されること）
        enum DummyError: Error { case testFailure }
        await mockResearcher.setStubbedResult(.failure(DummyError.testFailure))

        runtime.startTerminologyResearch(evidenceText: "Thunderbolt5についても調べる", evidenceID: "ev-3")
        await runtime.waitForIdle()

        // ノート数は増えず、errorMessageもnilのまま
        expectEqual(runtime.researchNotes.count, 1)
        expectTrue(runtime.errorMessage == nil)

        // 4. resetSession でリセットされること
        runtime.resetSession(demo: false)
        expectEqual(runtime.researchNotes.count, 0)
        expectEqual(runtime.researchedTerms.count, 0)
        expectEqual(runtime.inFlightTerms.count, 0)
    }

    /// 思考モデル・用語調査専用モデル・推論設定・Web検索設定の検証
    func testTerminologyResearchModelAndSearchSettings() {
        let settings = AppSettings()
        expectEqual(settings.thinkingModel, "gpt-6-sol")
        expectEqual(settings.thinkingEffort, "low")
        expectEqual(settings.terminologyResearchModel, "gpt-6-sol")
        expectEqual(settings.terminologyResearchEffort, "low")
        expectEqual(settings.enableTerminologyWebSearch, true)

        let adapter = CodexResearchAdapter()
        expectEqual(adapter.model, "gpt-6-sol")
        expectEqual(adapter.reasoningEffort, "low")
        expectEqual(adapter.enableWebSearch, true)

        let runtime = MeetingRuntime(settings: AppSettings())
        if let runtimeAdapter = runtime.researchClient as? CodexResearchAdapter {
            expectEqual(runtimeAdapter.model, "gpt-6-sol")
            expectEqual(runtimeAdapter.reasoningEffort, "low")
            expectEqual(runtimeAdapter.enableWebSearch, true)
        }
    }

    /// インフライト制御（同一用語が調査中に並列起動しないこと）の検証
    func testInFlightTermsPreventsParallelDuplicateExecution() async throws {
        let mockResearcher = MockTerminologyResearchClient()
        let note = ResearchNote(
            term: "ComputeExpressLink",
            summary: "CXL規格",
            detail: "次世代インターコネクト",
            sourceEngine: "codex (gpt-5.6-sol)",
            evidenceText: "ComputeExpressLinkについて話しましょう"
        )
        await mockResearcher.setStubbedResult(.success(note))

        let runtime = MeetingRuntime(researchClient: mockResearcher)
        runtime.running = true

        // 1回目の調査を起動（非同期で進行）
        runtime.startTerminologyResearch(evidenceText: "ComputeExpressLinkについて話しましょう", evidenceID: "cxl-1")
        // 完了を待たずに即座に同一用語の発話を投入
        runtime.startTerminologyResearch(evidenceText: "ComputeExpressLinkのバージョンは？", evidenceID: "cxl-2")

        await runtime.waitForIdle()

        // インフライトガードにより2件目は起動せず、callCountは1のまま
        let callCount = await mockResearcher.callCount
        expectEqual(callCount, 1)
        expectEqual(runtime.researchNotes.count, 1)
        expectEqual(runtime.inFlightTerms.count, 0)
        expectTrue(runtime.researchedTerms.contains("computeexpresslink"))
    }

    /// 一般的すぎる用語（API, JSON等）の二重防御の検証
    func testDoubleDefenseAgainstGenericTerms() async throws {
        expectTrue(RuleText.isCommonGenericTerm("API"))
        expectTrue(RuleText.isCommonGenericTerm("JSON"))
        expectTrue(RuleText.isCommonGenericTerm("AI"))
        expectTrue(RuleText.isCommonGenericTerm("UI"))
        expectTrue(RuleText.isCommonGenericTerm("Web"))
        expectTrue(RuleText.isCommonGenericTerm("HTTP"))
        expectTrue(RuleText.isCommonGenericTerm("PC"))
        expectTrue(RuleText.isCommonGenericTerm("OS"))
        expectFalse(RuleText.isCommonGenericTerm("OCuLink"))
        expectFalse(RuleText.isCommonGenericTerm("ComputeExpressLink"))

        let mockResearcher = MockTerminologyResearchClient()
        let genericNote = ResearchNote(
            term: "API",
            summary: "アプリケーションプログラミングインターフェース",
            detail: "ソフトウェア間の連携口",
            sourceEngine: "codex"
        )
        await mockResearcher.setStubbedResult(.success(genericNote))

        let runtime = MeetingRuntime(researchClient: mockResearcher)
        runtime.running = true

        // 一般用語単体の発話を投入 -> 事前フィルターでスキップされTask起動せず
        runtime.startTerminologyResearch(evidenceText: "API", evidenceID: "api-1")
        await runtime.waitForIdle()

        let callCount = await mockResearcher.callCount
        expectEqual(callCount, 0)
        expectEqual(runtime.researchNotes.count, 0)
    }

    /// wake と researchTerm が同時に発生しても音声会話をブロックしないこと
    func testWakeAndResearchTermDoNotBlockVoiceSession() async throws {
        let spyLive = TestLiveProviderSpy()
        let mockResearcher = MockTerminologyResearchClient()
        let note = ResearchNote(
            term: "OCuLink",
            summary: "外付け規格",
            detail: "詳細",
            sourceEngine: "codex"
        )
        await mockResearcher.setStubbedResult(.success(note))

        let runtime = MeetingRuntime(
            geminiLive: spyLive,
            researchClient: mockResearcher,
            geminiKeyOverride: "test-gemini-key"
        )
        runtime.running = true

        var router = DecisionRouter()
        let policy = MeetingPolicy(nickname: "相棒")
        let ev = TranscriptEvent(id: "wake-research", text: "相棒、OCuLinkについてどう思う？", source: .meeting, isFinal: true)
        let judgment = Judgment(wakeScore: 1.0, termResearchScore: 0.9)
        let decisions = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0)

        expectEqual(decisions.map(\.action), [.wake, .researchTerm])

        // dispatchDecision で両方ディスパッチ
        await runtime.dispatchDecision(decisions[0], for: ev)
        await runtime.dispatchDecision(decisions[1], for: ev)

        await runtime.waitForIdle()

        expectEqual(runtime.researchNotes.count, 1)
        expectEqual(runtime.researchNotes.first?.term, "OCuLink")
    }

    /// ResearchSource のURL安全性・サニタイズ（http/httpsのみ、不正URL除外、重複排除、最大3件制限）の検証
    func testResearchSourceSecurityAndSanitization() throws {
        // 1. URL安全性チェック
        expectTrue(ResearchSource.isValidWebURL("https://example.com/spec"))
        expectTrue(ResearchSource.isValidWebURL("http://example.com/api"))
        expectFalse(ResearchSource.isValidWebURL("file:///etc/passwd"))
        expectFalse(ResearchSource.isValidWebURL("javascript:alert(1)"))
        expectFalse(ResearchSource.isValidWebURL("data:text/html,test"))
        expectFalse(ResearchSource.isValidWebURL("not-a-valid-url"))
        expectFalse(ResearchSource.isValidWebURL("https://")) // ホストなし

        // 2. sanitize の包括テスト:
        // - 不正URL除外
        // - 重複排除 (小文字同一化)
        // - 最大3件制限
        // - 将来の verifiedToolURLs 照合
        let rawSources = [
            ResearchSource(title: "Doc 1", url: "https://example.com/docs"),
            ResearchSource(title: "Malicious File", url: "file:///System/Library/CoreServices"),
            ResearchSource(title: "Doc 1 Dup", url: "HTTPS://EXAMPLE.COM/DOCS"),
            ResearchSource(title: "Doc 2", url: "https://example.com/spec"),
            ResearchSource(title: "Doc 3", url: "http://example.org/rfc"),
            ResearchSource(title: "Doc 4 Overflow", url: "https://example.net/overflow")
        ]

        let verifiedURLs: Set<String> = ["https://example.com/spec"]
        let sanitized = ResearchSource.sanitize(rawSources, verifiedToolURLs: verifiedURLs, maxCount: 3)

        expectEqual(sanitized.count, 3)
        expectEqual(sanitized[0].url, "https://example.com/docs")
        expectFalse(sanitized[0].isVerifiedToolSource)

        expectEqual(sanitized[1].url, "https://example.com/spec")
        expectTrue(sanitized[1].isVerifiedToolSource) // 照合一致

        expectEqual(sanitized[2].url, "http://example.org/rfc")
        expectFalse(sanitized[2].isVerifiedToolSource)

        // 3. ResearchNote init および JSONデコード時に自動サニタイズが適用されること
        let note = ResearchNote(
            term: "TestTerm",
            summary: "要約",
            detail: "詳細",
            sources: rawSources
        )
        expectEqual(note.sources.count, 3)
        expectFalse(note.sources.contains { $0.url.hasPrefix("file://") })

        let json = """
        {
            "term": "TestJson",
            "summary": "要約",
            "detail": "詳細",
            "sources": [
                {"title": "File", "url": "file:///path/to/secret"},
                {"title": "Valid HTTPS", "url": "https://secure.example.com"}
            ]
        }
        """.data(using: .utf8)!

        let decodedNote = try JSONDecoder().decode(ResearchNote.self, from: json)
        expectEqual(decodedNote.sources.count, 1)
        expectEqual(decodedNote.sources.first?.url, "https://secure.example.com")
    }

    /// 用語調査のキューイングと並列度制限（同時実行最大1、キュー最大3）の検証
    func testTerminologyResearchQueueLimitsConcurrencyToOne() async throws {
        let mockResearcher = MockTerminologyResearchClient(delayNanoseconds: 50_000_000) // 各調査に50ms

        let runtime = MeetingRuntime(researchClient: mockResearcher)
        runtime.running = true

        // 5つの異なる用語を短時間に連続投入
        let terms = [
            ("ev-1", "NVLinkの帯域幅について"),
            ("ev-2", "Infinibandの接続方式について"),
            ("ev-3", "RDMAのレイテンシについて"),
            ("ev-4", "RoCEv2のプロトコルについて"),
            ("ev-5", "UltraEthernetのコンソーシアムについて")
        ]

        for (id, text) in terms {
            runtime.startTerminologyResearch(evidenceText: text, evidenceID: id)
        }

        // 投入直後の状態: 1件実行中、キューには最大3件（ev-2はev-5投入時に溢れてFIFO破棄）
        expectLessThanOrEqual(runtime.pendingResearchCount, 3)

        // すべての処理完了まで待機
        await runtime.waitForIdle(timeoutSeconds: 5)

        let maxConcurrent = await mockResearcher.maxObservedConcurrentCalls
        let totalCalls = await mockResearcher.callCount

        // 並列実行数が1を決して超えないこと
        expectEqual(maxConcurrent, 1)
        // キュー上限3件により、最古のキューアイテム（ev-2）が破棄され、合計4件以下のみ実行されたこと
        expectLessThanOrEqual(totalCalls, 4)
        // 完了後はキューとインフライトが空
        expectEqual(runtime.pendingResearchCount, 0)
        expectEqual(runtime.inFlightTerms.count, 0)
    }

    /// 音声会話（wakeVoice）中に用語調査キューが稼働しても音声応答をブロックしないことの検証
    func testWakeDuringActiveResearchQueueDoesNotBlockVoice() async throws {
        let spyLive = TestLiveProviderSpy()
        let mockResearcher = MockTerminologyResearchClient(shouldBlockUntilReleased: true)

        let runtime = MeetingRuntime(
            geminiLive: spyLive,
            researchClient: mockResearcher,
            geminiKeyOverride: "test-gemini-key"
        )
        runtime.running = true

        // 1. ブロック状態の用語調査をキューに投入
        runtime.startTerminologyResearch(evidenceText: "ComputeExpressLinkの仕様", evidenceID: "cxl-heavy")

        // 調査タスクが起動しアクティブ状態に入るまで待機
        for _ in 0..<50 {
            let active = await mockResearcher.currentActiveCount
            if runtime.isResearching && active > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        expectTrue(runtime.isResearching)

        // 2. 用語調査がブロックされた状態のまま、音声呼び出し（wakeVoice）を実行
        let start = Date()
        await runtime.wakeVoice(prompt: "サイドキック、聞こえる？")
        let elapsed = Date().timeIntervalSince(start)

        // wakeVoiceが用語調査の完了を待たずに即時応答できていること
        expectTrue(spyLive.connectCalled)
        // wakeVoice完了時点でも用語調査は依然として実行中（非ブロック完了を論理的に証明）
        expectTrue(runtime.isResearching)
        let activeCalls = await mockResearcher.currentActiveCount
        expectEqual(activeCalls, 1)

        // 3. 用語調査のブロックを解放して完了待機
        await mockResearcher.releaseGate()
        await runtime.waitForIdle(timeoutSeconds: 5)
        expectEqual(runtime.isResearching, false)
        expectTrue(elapsed >= 0) // 診断用参照
    }

    /// CLI環境変数のPATH補強テスト: 既存PATHの維持、重複排除、必須パスの包含
    func testCLIEnvironmentAugmentedPathPreservesExistingAndDeduplicates() {
        let current = "/custom/tools:/usr/bin:/bin:/usr/local/bin:/usr/bin:/custom/tools"
        let augmented = CLIEnvironment.augmentedPath(currentPath: current, homeDirectory: "/Users/dummy")
        let parts = augmented.split(separator: ":").map(String.init)

        // 1. 既存PATHの先頭要素が最優先で保持されていること
        expectEqual(parts.first, "/custom/tools")

        // 2. 重複排除が行われていること（各要素が1度しか出現しない）
        var seen = Set<String>()
        for part in parts {
            expectTrue(seen.insert(part).inserted)
        }

        // 3. 最低限必須パスがすべて含まれていること
        for required in CLIEnvironment.minimumRequiredPaths {
            expectTrue(parts.contains(required))
        }

        // 4. nil/空文字時でも必須パスが含まれること
        let fallback = CLIEnvironment.augmentedPath(currentPath: nil, homeDirectory: "/Users/dummy")
        for required in CLIEnvironment.minimumRequiredPaths {
            expectTrue(fallback.contains(required))
        }
    }

    /// GUIアプリ起動時と同等の最小PATHでも codex --version が exit 0 で成功することを検証
    func testCLIRunsCodexWithMinimalGUIPath() async throws {
        let client = CLITextClient()
        let codexPath = client.resolveExecutable("codex")
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            return
        }

        // GUI環境に近い最小PATH（/usr/local/bin を含まない）
        // 補強なしでは env: node: No such file or directory (exit 127) になる
        let minimalGUIEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let result = try await client.runProcess(
            executablePath: codexPath,
            arguments: ["--version"],
            timeoutSeconds: 5,
            environment: minimalGUIEnv
        )

        expectEqual(result.exitCode, 0)
        expectTrue(result.stdout.contains("codex"))
    }

    /// 音声認識用の contextualStrings 構築テスト: キーワード抽出、動的マージ、重複排除、上限遵守
    func testContextualStringsConstructionAndDeduplication() {
        // 1. キーワード抽出テスト
        let text = "eGPUならOCuLinkかな。Next.js 15とSwiftUIを使ってマイクロサービスを試作する。the, and, 2026等は除外。"
        let keywords = SpeechContextVocabulary.extractKeywords(from: text)
        expectTrue(keywords.contains("eGPU"))
        expectTrue(keywords.contains("OCuLink"))
        expectTrue(keywords.contains("Next.js"))
        expectTrue(keywords.contains("SwiftUI"))
        expectTrue(keywords.contains("マイクロサービス"))
        expectFalse(keywords.contains("the"))
        expectFalse(keywords.contains("and"))
        expectFalse(keywords.contains("2026"))

        // 2. buildContextualStrings のマージおよび重複排除テスト
        let base = SpeechContextVocabulary.defaultBaseVocabulary
        let contextual = SpeechContextVocabulary.buildContextualStrings(
            baseVocabulary: base,
            objective: "eGPUとOCuLinkの性能比較",
            projectContext: "RDMAおよびCXLの調査",
            recentTerms: ["oculink", "NVLink", "カスタム用語"],
            limit: 50
        )

        // 基本語彙が最優先かつすべて含まれること
        for item in base {
            expectTrue(contextual.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }))
        }
        // 重複排除（大文字小文字問わず1度のみ）
        var seen = Set<String>()
        for term in contextual {
            expectTrue(seen.insert(term.lowercased()).inserted)
        }
        // 上限50以下であること
        expectLessThanOrEqual(contextual.count, 50)
    }

    /// CLIエラー時のstderrサニタイズ（秘密情報マスクとtail抽出）テスト
    func testCLISanitizesStderrDiagnostics() {
        // Synthetic fixtures only; construct recognizable formats without
        // embedding token-shaped literals in the repository.
        let fakeOpenAIKey = "sk-proj-" + String(repeating: "0", count: 24)
        let fakeTypeSafeKey = "ts-" + String(repeating: "0", count: 16)
        let raw = """
        [INFO] Loading credentials
        Authorization: Bearer secret_token_value_12345
        api_key: \(fakeOpenAIKey)
        ts_key = \(fakeTypeSafeKey)
        Error: Model 'custom-model' failed to initialize.
        Stack trace line 1
        Stack trace line 2
        """
        let sanitized = CLIOutputDiagnostics.sanitize(raw, maxBytes: 500)
        expectFalse(sanitized.contains("secret_token_value_12345"))
        expectFalse(sanitized.contains(fakeOpenAIKey))
        expectFalse(sanitized.contains(fakeTypeSafeKey))
        expectTrue(sanitized.contains("[REDACTED]"))
        expectTrue(sanitized.contains("Error: Model 'custom-model' failed to initialize."))

        // 長大なテキストの末尾抽出テスト
        let longText = String(repeating: "Line of logs\n", count: 500) + "FATAL: End of log file"
        let tail = CLIOutputDiagnostics.sanitize(longText, maxBytes: 100)
        expectTrue(tail.contains("FATAL: End of log file"))
        expectTrue(tail.contains("先頭省略"))
        expectLessThanOrEqual(tail.utf8.count, 200)
    }

    /// Codex引数の安全性テスト: 基本はskipGitRepoCheck=falseでbypass無効、指定時のみ有効、-C指定の検証
    func testCodexArgumentsWorkingDirectoryAndSkipGitRepoCheck() {
        // 1. デフォルト (skipGitRepoCheck = false, workingDirectory = nil)
        let defaultArgs = CLITextClient.buildCodexArguments(
            prompt: "テストプロンプト",
            outputFilePath: "/tmp/out.txt"
        )
        expectTrue(defaultArgs.contains("read-only"))
        expectTrue(defaultArgs.contains("--ephemeral"))
        expectFalse(defaultArgs.contains("--skip-git-repo-check"))
        expectFalse(defaultArgs.contains("-C"))

        // 2. 用語調査等の明示的指定 (skipGitRepoCheck = true, workingDirectory = "/known/dir")
        let researchArgs = CLITextClient.buildCodexArguments(
            prompt: "用語調査プロンプト",
            outputFilePath: "/tmp/out.txt",
            model: "gpt-5.6-sol",
            enableSearch: true,
            workingDirectory: "/known/dir",
            skipGitRepoCheck: true
        )
        expectTrue(researchArgs.contains("--search"))
        expectTrue(researchArgs.contains("read-only"))
        expectTrue(researchArgs.contains("--ephemeral"))
        expectTrue(researchArgs.contains("--skip-git-repo-check"))
        expectTrue(researchArgs.contains("-C"))
        if let idx = researchArgs.firstIndex(of: "-C") {
            expectEqual(researchArgs[idx + 1], "/known/dir")
        }
    }

    /// AppServer のリクエストパラメータおよび低負荷モデル解決の検証
    func testCodexAppServerParametersAndSmartModelResolution() async throws {
        let process = CodexAppServerProcess()
        let req1 = try await process.resolveModel(requested: "gpt-6-sol")
        expectEqual(req1, "gpt-6-sol")

        let request = CodexRequest(
            prompt: "調査依頼",
            model: "gpt-6-sol",
            reasoningEffort: "low",
            enableSearch: true,
            workingDirectory: AppPaths.project.path,
            skipGitRepoCheck: true
        )
        expectEqual(request.model, "gpt-6-sol")
        expectEqual(request.reasoningEffort, "low")
        expectEqual(request.enableSearch, true)
        expectEqual(request.workingDirectory, AppPaths.project.path)
        expectTrue(request.skipGitRepoCheck)
    }

    /// Sol指定時に利用可能モデルにSol系が一切ない場合、勝手にAstra等に落とさずmodelUnavailableエラーになることの検証
    func testCodexAppServerStrictSolFallback() async throws {
        let process = CodexAppServerProcess()

        // 1. Sol系のみ存在する場合
        await process.setAvailableModelsForTesting(["gpt-6-sol", "gpt-5.6-sol", "claude-3-7"])
        let m1 = try await process.resolveModel(requested: "gpt-6-sol")
        expectEqual(m1, "gpt-6-sol")

        // 2. gpt-6-sol が無く gpt-5.6-sol がある場合 -> gpt-5.6-sol へフォールバック
        await process.setAvailableModelsForTesting(["gpt-5.6-sol", "gpt-6-astra"])
        let m2 = try await process.resolveModel(requested: "gpt-6-sol")
        expectEqual(m2, "gpt-5.6-sol")

        // 3. Sol系が一切なく gpt-6-astra しかない場合 -> 勝手にAstraへ落とさず modelUnavailable エラー
        await process.setAvailableModelsForTesting(["gpt-6-astra", "gpt-5.2"])
        do {
            _ = try await process.resolveModel(requested: "gpt-6-sol")
            report(false, "Sol不在時にAstraへの勝手なフォールバックを防ぎエラーにすべき", file: #filePath, line: #line)
        } catch let error as CodexAppServerError {
            expectEqual(error, .modelUnavailable("gpt-6-sol"))
        } catch {
            report(false, "期待と異なるエラー型: \(error)", file: #filePath, line: #line)
        }

        // 4. 明示的に gpt-6-astra を希望した場合は利用可能ならそのまま許可
        let mAstra = try await process.resolveModel(requested: "gpt-6-astra")
        expectEqual(mAstra, "gpt-6-astra")

        // 5. 明示指定したモデルが存在しない場合はエラー
        do {
            _ = try await process.resolveModel(requested: "unknown-custom-model")
            report(false, "存在しない明示モデルはエラーにすべき", file: #filePath, line: #line)
        } catch let error as CodexAppServerError {
            expectEqual(error, .modelUnavailable("unknown-custom-model"))
        } catch {
            report(false, "期待と異なるエラー型: \(error)", file: #filePath, line: #line)
        }
    }

    /// AppServer の Web検索指定が thread/start config.web_search="live" であり、turn/start から未知フィールドが除去されていることの検証
    func testCodexAppServerWebSearchSchemaLiveAndDisabled() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = tempDir.appendingPathComponent("mock_app_server.py").path
        let logPath = tempDir.appendingPathComponent("received_params.json").path

        let pythonScript = """
import sys, json

log_path = "\(logPath)"
received = {}

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except:
        continue
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {}}) + "\\n")
        sys.stdout.flush()
    elif method == "model/list":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"data": [{"id": "gpt-6-sol"}]}}) + "\\n")
        sys.stdout.flush()
    elif method == "thread/start":
        received["thread_config"] = params.get("config", {})
        with open(log_path, "w") as f:
            json.dump(received, f)
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"thread": {"id": "t-123"}}}) + "\\n")
        sys.stdout.flush()
    elif method == "turn/start":
        received["turn_has_webSearch"] = "webSearch" in params
        received["turn_model"] = params.get("model")
        with open(log_path, "w") as f:
            json.dump(received, f)
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"turn": {"id": "turn-123"}}}) + "\\n")
        sys.stdout.flush()
        if received.get("thread_config", {}).get("web_search") == "live":
            web_notif = {
                "jsonrpc": "2.0",
                "method": "item/completed",
                "params": {
                    "threadId": "t-123",
                    "item": {
                        "type": "webSearch",
                        "id": "s-1",
                        "results": [{"url": "https://pcisig.com/spec"}]
                    }
                }
            }
            sys.stdout.write(json.dumps(web_notif) + "\\n")
            sys.stdout.flush()
        notif = {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": "t-123",
                "turn": {
                    "id": "turn-123",
                    "status": "completed",
                    "items": [{"type": "agentMessage", "text": "OK"}]
                }
            }
        }
        sys.stdout.write(json.dumps(notif) + "\\n")
        sys.stdout.flush()
"""
        try pythonScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let shPath = tempDir.appendingPathComponent("mock_codex").path
        let shScript = "#!/bin/sh\nexec /usr/bin/python3 -u \"\(scriptPath)\" \"$@\"\n"
        try shScript.write(toFile: shPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shPath)

        // 1. enableSearch == true の検証
        let process1 = CodexAppServerProcess()
        let req1 = CodexRequest(
            prompt: "検索テスト",
            model: "gpt-6-sol",
            reasoningEffort: "low",
            enableSearch: true,
            timeoutSeconds: 10,
            workingDirectory: tempDir.path
        )
        let res1 = try await process1.executeTurn(
            request: req1,
            executablePath: shPath,
            defaultWorkingDirectory: tempDir.path
        )
        expectEqual(res1.text, "OK")
        expectEqual(res1.backend, "app-server")
        expectEqual(res1.webSearchMode, "live")
        expectEqual(res1.webSearchRequested, true)
        expectEqual(res1.webSearchUsed, true)
        expectEqual(res1.webSearchSources, ["https://pcisig.com/spec"])
        await process1.stop()

        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let threadConfig = json["thread_config"] as? [String: Any]
            expectEqual(threadConfig?["web_search"] as? String, "live")
            expectEqual(json["turn_has_webSearch"] as? Bool, false)
        } else {
            report(false, "パラメータログのパース失敗", file: #filePath, line: #line)
        }

        // 2. enableSearch == false の検証
        try? FileManager.default.removeItem(atPath: logPath)
        let process2 = CodexAppServerProcess()
        let req2 = CodexRequest(
            prompt: "検索なしテスト",
            model: "gpt-6-sol",
            reasoningEffort: "low",
            enableSearch: false,
            timeoutSeconds: 10,
            workingDirectory: tempDir.path
        )
        let res2 = try await process2.executeTurn(
            request: req2,
            executablePath: shPath,
            defaultWorkingDirectory: tempDir.path
        )
        expectEqual(res2.text, "OK")
        expectEqual(res2.webSearchMode, "disabled")
        expectEqual(res2.webSearchRequested, false)
        expectEqual(res2.webSearchUsed, false)
        expectEqual(res2.webSearchSources, [])
        await process2.stop()

        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let threadConfig = json["thread_config"] as? [String: Any]
            expectEqual(threadConfig?["web_search"] as? String, "disabled")
            expectEqual(json["turn_has_webSearch"] as? Bool, false)
        } else {
            report(false, "パラメータログのパース失敗", file: #filePath, line: #line)
        }
    }

    /// AppServer への同時リクエストが排他制御（ターンロック）により安全に順次処理されることの検証
    func testCodexAppServerSerializesConcurrentTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = tempDir.appendingPathComponent("mock_concurrent_server.py").path
        let pythonScript = """
import sys, json, time

def log(msg):
    with open("/tmp/mock_concurrent.log", "a") as f:
        f.write(msg + "\\n")

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    log(f"RECV: {line}")
    try:
        req = json.loads(line)
    except Exception as e:
        log(f"ERR: {e}")
        continue
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method == "initialize":
        res = json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {}})
        log(f"SEND: {res}")
        sys.stdout.write(res + "\\n")
        sys.stdout.flush()
    elif method == "model/list":
        res = json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"data": [{"id": "gpt-6-sol"}]}})
        log(f"SEND: {res}")
        sys.stdout.write(res + "\\n")
        sys.stdout.flush()
    elif method == "thread/start":
        res = json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"thread": {"id": f"t-{req_id}"}}})
        log(f"SEND: {res}")
        sys.stdout.write(res + "\\n")
        sys.stdout.flush()
    elif method == "turn/start":
        text = params.get("input", [{}])[0].get("text", "")
        thread_id = params.get("threadId", "")
        turn_id = f"turn-{req_id}"
        time.sleep(0.04)
        res = json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"turn": {"id": turn_id}}})
        log(f"SEND: {res}")
        sys.stdout.write(res + "\\n")
        sys.stdout.flush()
        notif = json.dumps({
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": thread_id,
                "turn": {
                    "id": turn_id,
                    "status": "completed",
                    "items": [{"type": "agentMessage", "text": f"echo_{text}"}]
                }
            }
        })
        log(f"SEND NOTIF: {notif}")
        sys.stdout.write(notif + "\\n")
        sys.stdout.flush()
"""
        try pythonScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let shPath = tempDir.appendingPathComponent("mock_codex").path
        let shScript = "#!/bin/sh\nexec /usr/bin/python3 -u \"\(scriptPath)\" \"$@\"\n"
        try shScript.write(toFile: shPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shPath)

        let process = CodexAppServerProcess()
        let reqA = CodexRequest(prompt: "alpha", model: "gpt-6-sol", timeoutSeconds: 10, workingDirectory: tempDir.path)
        let reqB = CodexRequest(prompt: "beta", model: "gpt-6-sol", timeoutSeconds: 10, workingDirectory: tempDir.path)

        async let resA = process.executeTurn(request: reqA, executablePath: shPath, defaultWorkingDirectory: tempDir.path)
        async let resB = process.executeTurn(request: reqB, executablePath: shPath, defaultWorkingDirectory: tempDir.path)

        let (a, b) = try await (resA, resB)
        expectEqual(a.text, "echo_alpha")
        expectEqual(b.text, "echo_beta")
        await process.stop()
    }

    /// 正常終了時に restartCount が 0 にリセットされることの検証
    func testCodexAppServerRestartCountResetOnSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = tempDir.appendingPathComponent("mock_server.py").path
        let pythonScript = """
import sys, json
while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})
    if method == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {}}) + "\\n")
        sys.stdout.flush()
    elif method == "model/list":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"data": [{"id": "gpt-6-sol"}]}}) + "\\n")
        sys.stdout.flush()
    elif method == "thread/start":
        thread_id = f"t-{req_id}"
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"thread": {"id": thread_id}}}) + "\\n")
        sys.stdout.flush()
    elif method == "turn/start":
        thread_id = params.get("threadId", "t-1")
        turn_id = f"turn-{req_id}"
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"turn": {"id": turn_id}}}) + "\\n")
        sys.stdout.flush()
        notif = {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "items": [{"type": "agentMessage", "text": "DONE"}]}}
        }
        sys.stdout.write(json.dumps(notif) + "\\n")
        sys.stdout.flush()
"""
        try pythonScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let shPath = tempDir.appendingPathComponent("mock_codex").path
        let shScript = "#!/bin/sh\nexec /usr/bin/python3 -u \"\(scriptPath)\" \"$@\"\n"
        try shScript.write(toFile: shPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shPath)

        let backend = CodexAppServerBackend(
            executablePath: shPath,
            defaultWorkingDirectory: tempDir.path
        )
        let req = CodexRequest(prompt: "test", model: "gpt-6-sol", timeoutSeconds: 10, workingDirectory: tempDir.path)
        let r1 = try await backend.generate(req)
        expectEqual(r1.text, "DONE")
        expectEqual(backend.lastUsedBackend, "app-server")

        // 2回目のターンも正常に実行可能（restartCountが0に維持されている）
        let r2 = try await backend.generate(req)
        expectEqual(r2.text, "DONE")
        await backend.terminate()
    }

    /// AppServer 起動・実行失敗時に ExecBackend (fallback) へ正しくフォールバックすることの検証
    func testCodexAppServerFallbackToExecOnFailure() async throws {
        let mockFallback = MockCodexBackend(stringHandler: { req in
            "fallback_response_for_\(req.prompt)"
        })
        let backend = CodexAppServerBackend(
            executablePath: "/nonexistent/path/to/codex",
            fallbackBackend: mockFallback
        )
        let req = CodexRequest(prompt: "テストプロンプト")
        let result = try await backend.generate(req)
        expectEqual(result.text, "fallback_response_for_テストプロンプト")
        expectEqual(backend.lastUsedBackend, "exec")
        expectEqual(result.backend, "exec")
        expectEqual(mockFallback.generatedRequests.count, 1)
    }

    /// 思考失敗時に通常バナーへ簡潔なメッセージが表示され、詳細がアクティビティ（診断）へ記録されることの検証
    func testThinkingExecutionFailureSetsCleanBannerErrorMessageAndDetailsDiagnostic() async throws {
        let mockBackend = MockCodexBackend(stringHandler: { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Low level stderr connection refused detail"])
        })
        let runtime = MeetingRuntime(
            settings: AppSettings(),
            codexBackend: mockBackend,
            geminiKeyOverride: "dummy-key"
        )
        runtime.running = true
        await runtime.requestThinking(topic: "アーキテクチャを深く考えて")

        expectEqual(runtime.errorMessage, "考える処理を完了できませんでした。詳細は診断から確認できます。")
        expectFalse(runtime.errorMessage?.contains("Low level stderr connection refused detail") ?? true)
        let failureActivity = runtime.activities.first { $0.kind == "思考中断" }
        expectNotNil(failureActivity)
        expectTrue(failureActivity?.message.contains("Low level stderr connection refused detail") ?? false)
    }

    /// 音声認識の複数候補からドメイン語彙を含む候補を優先採用するセレクターの検証
    func testSpeechTranscriptionSelectorPrioritizesDomainVocabulary() {
        let best = "奥リンクならいいかも"
        let alternatives = ["奥リンクならいいかも", "OCuLinkならいいかも", "オキュリンクならいいかも"]
        let vocab = ["OCuLink", "eGPU"]

        let selection = SpeechTranscriptionSelector.selectCandidate(
            best: best,
            alternatives: alternatives,
            domainVocabulary: vocab
        )

        expectEqual(selection.rawTranscript, "奥リンクならいいかも")
        expectEqual(selection.normalizedTranscript, "OCuLinkならいいかも")
    }

    /// ベスト仮説と大きく乖離した候補が棄却され、類似した置換候補のみが採用される保守的判定の検証
    func testSpeechTranscriptionSelectorConservativeSelection() {
        let vocab = ["OCuLink", "eGPU"]

        // 1. ベスト候補と大きく乖離した誤認識候補（たまたまOCuLinkが含まれる）は棄却し、ベスト候補を維持
        let divergentBest = "今日の議題について話します"
        let divergentAlternatives = ["今日の議題について話します", "OCuLink 昨日の夜ご飯"]
        let sel1 = SpeechTranscriptionSelector.selectCandidate(
            best: divergentBest,
            alternatives: divergentAlternatives,
            domainVocabulary: vocab
        )
        expectEqual(sel1.rawTranscript, "今日の議題について話します")
        expectEqual(sel1.normalizedTranscript, "今日の議題について話します")

        // 2. ベスト候補と類似した同文脈の置換候補（オキュリンク -> OCuLink）は正常に採用
        let similarBest = "eGPUならオキュリンクかな"
        let similarAlternatives = ["eGPUならオキュリンクかな", "eGPUならOCuLinkかな"]
        let sel2 = SpeechTranscriptionSelector.selectCandidate(
            best: similarBest,
            alternatives: similarAlternatives,
            domainVocabulary: vocab
        )
        expectEqual(sel2.rawTranscript, "eGPUならオキュリンクかな")
        expectEqual(sel2.normalizedTranscript, "eGPUならOCuLinkかな")
    }

    /// ResearchNote の診断サマリー表示フォーマットの検証
    func testResearchNoteDiagnosticsSummary() {
        // 1. App Server 実使用検知 (webSearchUsed == true)
        let note = ResearchNote(
            term: "OCuLink",
            summary: "PCIe外部接続規格",
            detail: "詳細",
            sourceEngine: "codex (gpt-5.6-sol)",
            evidenceText: "eGPUならOCuLinkかな",
            sources: [ResearchSource(title: "PCI-SIG", url: "https://pcisig.com/spec", isVerifiedToolSource: true)],
            backend: "app-server",
            resolvedModel: "gpt-5.6-sol",
            reasoningEffort: "low",
            webSearchMode: "live",
            webSearchRequested: true,
            webSearchUsed: true
        )
        expectEqual(note.diagnosticsSummary, "app-server · gpt-5.6-sol · effort:low · web_search:live (req:true, used:true, sources:1)")

        // 2. Exec fallback (実使用未観測・テレメトリ不可: webSearchUsed == nil -> unknown)
        let execNote = ResearchNote(
            term: "OCuLink",
            summary: "PCIe外部接続規格",
            detail: "詳細",
            sourceEngine: "codex (gpt-6-sol)",
            evidenceText: "eGPUならOCuLinkかな",
            sources: [],
            backend: "exec",
            resolvedModel: "gpt-6-sol",
            reasoningEffort: "low",
            webSearchMode: "live",
            webSearchRequested: true,
            webSearchUsed: nil
        )
        expectEqual(execNote.diagnosticsSummary, "exec · gpt-6-sol · effort:low · web_search:live (req:true, used:unknown, sources:0)")

        // 3. App Server 検索無効 (webSearchUsed == false)
        let disabledNote = ResearchNote(
            term: "OCuLink",
            summary: "PCIe外部接続規格",
            detail: "詳細",
            sourceEngine: "codex (gpt-6-sol)",
            evidenceText: "eGPUならOCuLinkかな",
            sources: [],
            backend: "app-server",
            resolvedModel: "gpt-6-sol",
            reasoningEffort: "low",
            webSearchMode: "disabled",
            webSearchRequested: false,
            webSearchUsed: false
        )
        expectEqual(disabledNote.diagnosticsSummary, "app-server · gpt-6-sol · effort:low · web_search:disabled (req:false, used:false, sources:0)")
    }

    /// TranscriptEvent の rawTranscript と normalizedTranscript の分離・互換性の検証
    func testTranscriptEventRawAndNormalizedSeparation() throws {
        var event = TranscriptEvent(text: "OCuLink", rawTranscript: "奥リンク")
        expectEqual(event.text, "OCuLink")
        expectEqual(event.normalizedTranscript, "OCuLink")
        expectEqual(event.rawTranscript, "奥リンク")

        event.text = "eGPU"
        expectEqual(event.normalizedTranscript, "eGPU")
        expectEqual(event.text, "eGPU")

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: encoded)
        expectEqual(decoded.text, "eGPU")
        expectEqual(decoded.normalizedTranscript, "eGPU")
        expectEqual(decoded.rawTranscript, "奥リンク")
    }

    /// macOS 15+ 向け CustomLanguageModelHelper の準備状態の検証
    func testCustomLanguageModelHelperSupport() {
        expectTrue(CustomLanguageModelHelper.isSupportedOnCurrentOS)
        if #available(macOS 15.0, *) {
            let data = CustomLanguageModelHelper.createCustomLanguageModelData(vocabulary: ["OCuLink", "eGPU"])
            expectNotNil(data)
            let config = CustomLanguageModelHelper.makeConfiguration(modelURL: URL(fileURLWithPath: "/tmp/fake.bin"))
            expectNotNil(config)
        }
    }

    /// CodexAppServerProcess において、前のターン実行中に待機していたタスクがキャンセルされた場合、
    /// ロック解放後に待機タスクの turn/start が送信されずに直ちにキャンセルされることの検証
    func testCodexAppServerTurnWaitCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = tempDir.appendingPathComponent("mock_cancel_server.py").path
        let logPath = tempDir.appendingPathComponent("server.log").path

        let pythonScript = """
import sys, json, time

log_file = sys.argv[1]

def log(msg):
    with open(log_file, "a") as f:
        f.write(msg + "\\n")

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params", {})

    if method == "initialize":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {}}) + "\\n")
        sys.stdout.flush()
    elif method == "model/list":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"data": [{"id": "gpt-6-sol"}]}}) + "\\n")
        sys.stdout.flush()
    elif method == "thread/start":
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"thread": {"id": f"t-{req_id}"}}}) + "\\n")
        sys.stdout.flush()
    elif method == "turn/start":
        text = params.get("input", [{}])[0].get("text", "")
        thread_id = params.get("threadId", "")
        turn_id = f"turn-{req_id}"
        log(f"TURN_START: {text}")
        if text == "turnA":
            time.sleep(0.3)
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {"turn": {"id": turn_id}}}) + "\\n")
        sys.stdout.flush()
        notif = {
            "jsonrpc": "2.0",
            "method": "turn/completed",
            "params": {
                "threadId": thread_id,
                "turn": {
                    "id": turn_id,
                    "status": "completed",
                    "items": [{"type": "agentMessage", "text": f"resp_{text}"}]
                }
            }
        }
        sys.stdout.write(json.dumps(notif) + "\\n")
        sys.stdout.flush()
"""
        try pythonScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        let shPath = tempDir.appendingPathComponent("mock_codex").path
        let shScript = "#!/bin/sh\nexec /usr/bin/python3 -u \"\(scriptPath)\" \"\(logPath)\" \"$@\"\n"
        try shScript.write(toFile: shPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shPath)

        let process = CodexAppServerProcess()
        let reqA = CodexRequest(prompt: "turnA", model: "gpt-6-sol", timeoutSeconds: 10, workingDirectory: tempDir.path)
        let reqB = CodexRequest(prompt: "turnB", model: "gpt-6-sol", timeoutSeconds: 10, workingDirectory: tempDir.path)

        let taskA = Task {
            try await process.executeTurn(request: reqA, executablePath: shPath, defaultWorkingDirectory: tempDir.path)
        }

        // taskAが開始し、turnGateロックを取得してturnAの通信に入るまで待機
        try await Task.sleep(nanoseconds: 80_000_000)

        // taskBを起動（turnGate待ちに入る）
        let taskB = Task {
            try await process.executeTurn(request: reqB, executablePath: shPath, defaultWorkingDirectory: tempDir.path)
        }

        // taskBがwaiterに入るのを待機
        try await Task.sleep(nanoseconds: 50_000_000)

        // taskBをキャンセル
        taskB.cancel()

        // taskBの結果を確認（CancellationErrorをスローすること）
        do {
            _ = try await taskB.value
            report(false, "taskBはCancellationErrorで失敗すべき", file: #filePath, line: #line)
        } catch is CancellationError {
            // 期待通りキャンセルが伝播
        } catch {
            report(false, "予期しないエラー: \(error)", file: #filePath, line: #line)
        }

        // taskAは正常に完了すること
        let resA = try await taskA.value
        expectEqual(resA.text, "resp_turnA")

        await process.stop()

        // logPathを確認し、turnAのみが送信され、turnBのturn/startは一度も送信されていないことを検証
        let logs = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        expectTrue(logs.contains("TURN_START: turnA"))
        expectFalse(logs.contains("TURN_START: turnB"))
    }

    /// resetSession 呼び出し直後に新セッションが開始された場合、古い遅延 terminate が新セッションを妨害しないことの検証
    func testResetSessionAndBackendTerminateIsolation() async throws {
        let mockBackend = MockCodexBackend()
        let runtime = MeetingRuntime(
            settings: AppSettings(),
            codexBackend: mockBackend,
            geminiKeyOverride: "dummy-key"
        )

        // 1. セッション1の resetSession 呼び出し
        runtime.resetSession(demo: false)
        let gen1 = runtime.backendTerminateGeneration

        // 直後に新発話を受信して新セッションへ移行（generationがインクリメントされる）
        runtime.receive(TranscriptEvent(text: "新しい議題を開始します", source: .microphone, isFinal: true))
        let gen2 = runtime.backendTerminateGeneration
        expectGreaterThan(gen2, gen1)

        // 非同期terminateタスクが評価されるまで待機
        try? await Task.sleep(nanoseconds: 50_000_000)

        // gen1 の遅延 terminate は guard self.backendTerminateGeneration == gen により破棄されたため、
        // mockBackend.terminate は呼ばれていない
        expectFalse(mockBackend.terminated)

        // 2. resetSessionAsync による確実な停止
        await runtime.resetSessionAsync(demo: false)
        expectTrue(mockBackend.terminated)
    }

    /// カスタム言語モデル（CLM）の固定10用語による事前準備・キャッシュ機能の検証
    func testCustomLanguageModelPrewarmAndCache() async throws {
        let baseTerms = SpeechContextVocabulary.defaultBaseVocabulary
        expectEqual(baseTerms.count, 10)
        expectTrue(baseTerms.contains("OCuLink"))
        expectTrue(baseTerms.contains("eGPU"))
        expectTrue(baseTerms.contains("NVLink"))
        expectTrue(baseTerms.contains("Antigravity"))

        if #available(macOS 14.0, *) {
            let cache = CustomLanguageModelCache()
            let initialConfig = await cache.getCachedBaseConfiguration()
            expectTrue(initialConfig == nil)

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let data = CustomLanguageModelHelper.createCustomLanguageModelData(
                vocabulary: baseTerms,
                identifier: "test-cache-identifier"
            )
            let fileURL = tempDir.appendingPathComponent("test_clm.bin")
            try await data.export(to: fileURL)
            expectTrue(FileManager.default.fileExists(atPath: fileURL.path))

            let config = CustomLanguageModelHelper.makeConfiguration(modelURL: fileURL)
            expectNotNil(config)
        }
    }

    /// 最初の音声認識リクエストへのCLM適用（キャッシュあり、短時間準備、タイムアウト/失敗フォールバック）の検証
    func testCustomLanguageModelImmediateAndPrewarmApplicationToFirstRequest() async throws {
        if #available(macOS 14.0, *) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fakeModelURL = tempDir.appendingPathComponent("fake.bin")
            try Data("model".utf8).write(to: fakeModelURL)
            let mockConfig = CustomLanguageModelHelper.makeConfiguration(modelURL: fakeModelURL)

            // 1. cached CLMあり → 最初のrequestから適用
            let prewarmer1 = CustomLanguageModelPrewarmer()
            prewarmer1.setReadyConfigForTesting(mockConfig)
            let res1 = await prewarmer1.waitForConfiguration(timeoutSeconds: 1.0)
            expectNotNil(res1)
            let req1 = SFSpeechAudioBufferRecognitionRequest()
            CustomLanguageModelPrewarmer.configureRecognitionRequest(
                request: req1,
                clmConfig: res1,
                contextualStrings: ["OCuLink", "eGPU"]
            )
            expectNotNil(req1.customizedLanguageModel)
            expectTrue(req1.contextualStrings.contains("OCuLink"))

            // 2. CLM準備が短時間（30ms）で完了 → 最初から適用
            let prewarmer2 = CustomLanguageModelPrewarmer()
            let quickTask = Task<SFSpeechLanguageModel.Configuration?, Never> {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return mockConfig
            }
            prewarmer2.setPrewarmTaskForTesting(quickTask)
            let res2 = await prewarmer2.waitForConfiguration(timeoutSeconds: 1.0)
            expectNotNil(res2)
            let req2 = SFSpeechAudioBufferRecognitionRequest()
            CustomLanguageModelPrewarmer.configureRecognitionRequest(
                request: req2,
                clmConfig: res2,
                contextualStrings: ["OCuLink", "eGPU"]
            )
            expectNotNil(req2.customizedLanguageModel)
            expectTrue(req2.contextualStrings.contains("OCuLink"))

            // 3. CLM準備がタイムアウトまたは失敗 → 会議開始をブロックせず contextualStrings で即座に開始
            let prewarmer3 = CustomLanguageModelPrewarmer()
            let slowTask = Task<SFSpeechLanguageModel.Configuration?, Never> {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                return mockConfig
            }
            prewarmer3.setPrewarmTaskForTesting(slowTask)
            let startWait = Date()
            let res3 = await prewarmer3.waitForConfiguration(timeoutSeconds: 0.05) // 50msで打ち切り
            let elapsed = Date().timeIntervalSince(startWait)
            expectTrue(elapsed < 0.3) // 長時間ブロックしない
            expectTrue(res3 == nil)
            let req3 = SFSpeechAudioBufferRecognitionRequest()
            CustomLanguageModelPrewarmer.configureRecognitionRequest(
                request: req3,
                clmConfig: res3,
                contextualStrings: ["OCuLink", "eGPU"]
            )
            expectTrue(req3.customizedLanguageModel == nil) // CLM未完了
            expectTrue(req3.contextualStrings.contains("OCuLink")) // contextualStringsは確実に保持
        }
    }

    /// CodexExecBackend の webSearchUsed が nil (unknown) として扱われ、実イベントと誤認されないことの検証
    func testCodexExecBackendWebSearchUsedIsUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exec-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-fixture")
        let script = """
        #!/usr/bin/python3
        import pathlib, sys
        pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_text('fixture response')
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let backend = CodexExecBackend(executablePath: executable.path)
        let req = CodexRequest(prompt: "テスト", enableSearch: true)
        let res = try await backend.generate(req)
        expectEqual(res.backend, "exec")
        expectEqual(res.webSearchRequested, true)
        expectTrue(res.webSearchUsed == nil)
        expectEqual(res.webSearchSources, [])
    }
}

final class MockCodexBackend: CodexBackend, @unchecked Sendable {
    var generateHandler: ((CodexRequest) async throws -> CodexGenerationResult)?
    var stringHandler: ((CodexRequest) async throws -> String)?
    var generatedRequests: [CodexRequest] = []
    var terminated = false
    var terminateCallCount = 0
    var lastTerminatedGeneration: Int?

    init(generateHandler: ((CodexRequest) async throws -> CodexGenerationResult)? = nil) {
        self.generateHandler = generateHandler
        self.stringHandler = nil
    }

    init(stringHandler: @escaping (CodexRequest) async throws -> String) {
        self.generateHandler = nil
        self.stringHandler = stringHandler
    }

    func generate(_ request: CodexRequest) async throws -> CodexGenerationResult {
        generatedRequests.append(request)
        if let handler = generateHandler {
            return try await handler(request)
        }
        if let handler = stringHandler {
            let text = try await handler(request)
            return CodexGenerationResult(
                text: text,
                backend: "exec",
                requestedModel: request.model ?? "gpt-6-sol",
                resolvedModel: request.model ?? "gpt-6-sol",
                reasoningEffort: request.reasoningEffort ?? "low",
                webSearchMode: request.enableSearch ? "live" : "disabled",
                webSearchRequested: request.enableSearch,
                webSearchUsed: nil, // Exec fallbackでは実使用を観測できないため unknown (nil)
                webSearchSources: []
            )
        }
        return CodexGenerationResult(
            text: "mock_success",
            backend: "exec",
            requestedModel: request.model ?? "gpt-6-sol",
            resolvedModel: request.model ?? "gpt-6-sol",
            reasoningEffort: request.reasoningEffort ?? "low",
            webSearchMode: request.enableSearch ? "live" : "disabled",
            webSearchRequested: request.enableSearch,
            webSearchUsed: nil,
            webSearchSources: []
        )
    }

    func terminate() async {
        terminated = true
        terminateCallCount += 1
    }

    func terminate(targetGeneration: Int?) async {
        terminated = true
        terminateCallCount += 1
        lastTerminatedGeneration = targetGeneration
    }
}

@MainActor
final class DelayedJevJudge: RemoteJudging {
    var delayNanoseconds: UInt64 = 200_000_000 // 200ms
    var returnedJudgment = Judgment(buildScore: 1.0, topic: "遅延JEV試作案")
    var evaluateCalled = false

    func evaluate(event: TranscriptEvent, context: String, policy: MeetingPolicy, apiKey: String, endpoint: URL, model: String) async throws -> Judgment {
        evaluateCalled = true
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return returnedJudgment
    }
}

@MainActor
final class TestLiveProviderSpy: LiveConversationProvider {
    var onAudio: ((Data, Double) -> Void)?
    var onText: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onToolCall: ((String, [String: Any], String) -> Void)?

    var connectCalled = false
    var disconnectCalled = false
    var connectedModel = ""
    var sentTexts: [String] = []
    var isConnected = false

    func connect(apiKey: String, model: String, instructions: String) async throws {
        connectCalled = true
        connectedModel = model
        isConnected = true
    }
    func sendAudio(_ data: Data) async throws {}
    func sendFrame(_ jpeg: Data) async throws {}
    func sendText(_ text: String) async throws {
        sentTexts.append(text)
    }
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {}
    func disconnect() {
        isConnected = false
        disconnectCalled = true
    }
}
