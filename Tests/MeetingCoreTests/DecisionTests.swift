import Foundation
@testable import MeetingCore

final class DecisionTests {
    let now = Date(timeIntervalSince1970: 1_000)
    func event(_ text: String, id: String = "one", final: Bool = true, source: AudioSource = .manual) -> TranscriptEvent {
        TranscriptEvent(id: id, text: text, source: source, isFinal: final, timestamp: now)
    }
    func testPartialThenFinalAndDuplicate() {
        var router = DecisionRouter(); let p = MeetingPolicy(); let j = Judgment(buildScore: 1)
        expectTrue(router.route(event: event("作って", final: false), judgment: j, policy: p, activeJobID: nil, totalJobs: 0, now: now).isEmpty)
        expectEqual(router.route(event: event("アプリを作って"), judgment: j, policy: p, activeJobID: nil, totalJobs: 0, now: now).map(\.action), [.build])
        expectTrue(router.route(event: event("アプリを作って"), judgment: j, policy: p, activeJobID: nil, totalJobs: 0, now: now).isEmpty)
    }
    func testNegationOverridesWrongModel() {
        for text in ["作って…いや、作らなくていい", "作ってほしくない", "do not build an app"] {
            var router = DecisionRouter()
            expectTrue(router.route(event: event(text), judgment: Judgment(buildScore: 1), policy: MeetingPolicy(), activeJobID: nil, totalJobs: 0, now: now).isEmpty)
        }
    }
    func testStopIgnoresBudgetAndCooldown() {
        var router = DecisionRouter()
        expectEqual(router.route(event: event("制作を止めて"), judgment: Judgment(buildScore: 1, stopScore: 1), policy: MeetingPolicy(maxJobs: 0), activeJobID: "job", totalJobs: 10, now: now).map(\.action), [.stop])
    }
    func testAssistantAndStaleAreNotActions() {
        var router = DecisionRouter()
        expectTrue(router.route(event: event("作って", source: .assistant), judgment: Judgment(buildScore: 1), policy: MeetingPolicy(), activeJobID: nil, totalJobs: 0, now: now).isEmpty)
        expectTrue(router.route(event: event("作って"), judgment: Judgment(buildScore: 1), policy: MeetingPolicy(), activeJobID: nil, totalJobs: 0, now: now.addingTimeInterval(100)).isEmpty)
    }
    func testWakeAndBuildCanHappenTogetherButNotDoubleVoice() {
        var router = DecisionRouter()
        let result = router.route(event: event("サイドキック、メモアプリがあると便利"), judgment: Judgment(wakeScore: 1, buildScore: 1, speakScore: 1), policy: MeetingPolicy(proactiveSpeech: true), activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(result.map(\.action), [.wake, .build])
    }
    func testLocalIdeaAndNegatedStop() {
        let p = MeetingPolicy(objective: "会議メモアプリ")
        expectGreaterThan(LocalRuleJudge.evaluate(event: event("メモアプリがあったら便利"), policy: p).buildScore, 0.7)
        expectEqual(LocalRuleJudge.evaluate(event: event("制作を止めないで"), policy: p).stopScore, 0)
    }
    func testContextDoesNotOverwriteFinalWithLatePartial() {
        var context = ContextStore()
        context.append(event("確定しました")); context.append(event("確定", final: false))
        expectTrue(context.recent().contains("確定しました"))
        expectLessThanOrEqual(context.recent(maxCharacters: 25).count, 25)
    }
    func testNonfiniteScoresFailClosed() {
        var router = DecisionRouter()
        expectTrue(router.route(event: event("アプリ"), judgment: Judgment(buildScore: .nan, stopScore: .infinity), policy: MeetingPolicy(), activeJobID: nil, totalJobs: 0, now: now).isEmpty)
    }
    func testAcceptanceCondition1_AutoBuildWithoutExplicitCommand() {
        // 条件1: 会議目的に合うアイデアが出たら、明示依頼なしで試作が1件だけ始まる
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "議事録ツール", autoBuild: true, maxJobs: 1)
        let judgeResult = LocalRuleJudge.evaluate(event: event("議事録を自動でまとめるツールがあったら便利"), policy: policy)
        expectGreaterThan(judgeResult.buildScore, 0.7)
        let actions = router.route(event: event("議事録を自動でまとめるツールがあったら便利"), judgment: judgeResult, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.build])
        // 上限に達している場合は2件目は開始しない
        let secondActions = router.route(event: event("別のアイデア", id: "two"), judgment: judgeResult, policy: policy, activeJobID: "job1", totalJobs: 1, now: now)
        expectTrue(secondActions.isEmpty)
    }
    func testAcceptanceCondition2_WakeAndNoSelfReaction() {
        // 条件2: 名前で呼ぶと返答、AI自身の発話では再起動しない
        var router = DecisionRouter()
        let policy = MeetingPolicy(nickname: "相棒")
        let humanEvent = event("相棒、今の話についてどう思う？", source: .meeting)
        let humanActions = router.route(event: humanEvent, judgment: Judgment(wakeScore: 1), policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(humanActions.map(\.action), [.wake])

        let assistantEvent = event("相棒、制作を始めます", source: .assistant)
        let assistantActions = router.route(event: assistantEvent, judgment: Judgment(wakeScore: 1), policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(assistantActions.isEmpty)
    }
    func testAcceptanceCondition3_NegationAndDuplicateRejection() {
        // 条件3: 否定・言い直し・同一発言の再送で誤着手・二重着手しない
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let negated = event("アプリを作って…いや、作るのはやめよう")
        expectTrue(router.route(event: negated, judgment: Judgment(buildScore: 0.95), policy: policy, activeJobID: nil, totalJobs: 0, now: now).isEmpty)

        let initial = event("カレンダーアプリを作って", id: "task1")
        let first = router.route(event: initial, judgment: Judgment(buildScore: 1), policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(first.map(\.action), [.build])
        let duplicate = router.route(event: initial, judgment: Judgment(buildScore: 1), policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(duplicate.isEmpty)
    }
    func testAcceptanceCondition4_StaleUtterancesDropped() {
        // 条件4: 人の発言を優先し、遅れて不要になった古い発言は破棄
        var router = DecisionRouter(staleAfterSeconds: 45)
        let oldEvent = TranscriptEvent(id: "old", text: "ツッコミを入れて", source: .meeting, isFinal: true, timestamp: now.addingTimeInterval(-60))
        expectTrue(router.route(event: oldEvent, judgment: Judgment(speakScore: 1), policy: MeetingPolicy(proactiveSpeech: true), activeJobID: nil, totalJobs: 0, now: now).isEmpty)
    }
    func testAcceptanceCondition5_ModifyAndImmediateStop() {
        // 条件5: 作業途中の修正・停止が反映される
        var router = DecisionRouter()
        let modifyEvent = event("文字を赤色に変えて", id: "mod1")
        let modifyActions = router.route(event: modifyEvent, judgment: Judgment(modifyScore: 1), policy: MeetingPolicy(), activeJobID: "active-job", totalJobs: 1, now: now)
        expectEqual(modifyActions.map(\.action), [.modify])

        let stopEvent = event("制作を中止して", id: "stop1")
        let stopActions = router.route(event: stopEvent, judgment: Judgment(stopScore: 1), policy: MeetingPolicy(), activeJobID: "active-job", totalJobs: 1, now: now)
        expectEqual(stopActions.map(\.action), [.stop])
    }

    func testCriteriaRespectsDoNotBuild() {
        let policy = MeetingPolicy(
            objective: "Webアプリ制作",
            doNotBuildCriteria: ["決済API連携", "認証基盤"]
        )
        // 「決済API連携を作って」と言われても doNotBuildCriteria に合致するため buildScore は 0 に抑止される
        let result = LocalRuleJudge.evaluate(event: event("決済API連携のアプリを作って"), policy: policy)
        expectEqual(result.buildScore, 0)
    }

    func testCriteriaTriggersCustomBuild() {
        let policy = MeetingPolicy(
            objective: "業務自動化",
            buildCriteria: ["UIレイアウト確定", "画面遷移図"]
        )
        // カスタム基準「画面遷移図」が含まれている場合、buildScore が閾値を超える
        let result = LocalRuleJudge.evaluate(event: event("画面遷移図がまとまったね"), policy: policy)
        expectGreaterThan(result.buildScore, 0.7)
    }

    func testCriteriaTriggersCustomSpeak() {
        let policy = MeetingPolicy(
            objective: "業務自動化",
            speakCriteria: ["仕様の矛盾", "非現実的な納期"]
        )
        // カスタムツッコミ基準「仕様の矛盾」が含まれている場合、speakScore が付与される
        let result = LocalRuleJudge.evaluate(event: event("ここに仕様の矛盾があるかも"), policy: policy)
        expectGreaterThan(result.speakScore, 0.7)
    }

    /// 仕様書v0.2 受け入れ条件9: JEVが思考の必要性を検知したら、該当文脈を渡して思考・計画（think）を起動し、この動作だけでは制作ジョブ（build）を開始しない
    func testAcceptanceCondition9_JevThinkActionDoesNotTriggerBuildJob() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "日常のライフログからアプリを作る", autoBuild: true, maxJobs: 3)
        let ev = event("DBの設計について、SQLiteとCoreDataのどちらが良いか深く考えて比較してほしい")

        // 思考・検討のスコアが高く、制作スコアは閾値未満の判定
        let judgment = Judgment(
            wakeScore: 0,
            buildScore: 0.2, // 制作スコアは低い
            modifyScore: 0,
            stopScore: 0,
            speakScore: 0,
            thinkScore: 0.95, // 思考依頼
            topic: "SQLiteとCoreDataの比較検討"
        )

        let actions = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        // .think アクションが含まれ、.build は含まれないこと
        expectTrue(actions.contains(where: { $0.action == .think }))
        expectFalse(actions.contains(where: { $0.action == .build }))
    }

    /// ローカルルール判定でも思考・計画のキーワードが検出されることを検証
    func testLocalRuleJudgeDetectsThinkingRequest() {
        let policy = MeetingPolicy(objective: "業務自動化")
        let result = LocalRuleJudge.evaluate(event: event("このアーキテクチャのトレードオフを深く考えて比較してみて"), policy: policy)
        expectGreaterThan(result.thinkScore, 0.7)
    }

    /// AG.md要件: thinkとbuildが両方高い場合、明示的な制作指示がなければthinkを優先しbuildを排他的に抑制する
    func testThinkVsBuildPriorityWhenBothScoresHighWithoutExplicitCommand() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "業務自動化ツールを作る", autoBuild: true, maxJobs: 3)
        let ev = event("ReactとVueのどちらを採用すべきか深く比較検討してみてほしい")

        // thinkとbuildの両方が閾値を超えている判定
        let judgment = Judgment(
            wakeScore: 0,
            buildScore: 0.85,
            modifyScore: 0,
            stopScore: 0,
            speakScore: 0,
            thinkScore: 0.95,
            topic: "ReactとVueの比較"
        )

        let actions = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        // 明示的な作成指示がないため、.think が優先され .build は排他抑制されること
        expectTrue(actions.contains(where: { $0.action == .think }))
        expectFalse(actions.contains(where: { $0.action == .build }))
    }

    /// AG.md要件: 音声AI自身に制作権限を持たせない。autoBuildがfalseの場合、voice_tool提案は自動開始されず保留されること
    func testVoiceToolCannotBypassAutoBuildPolicyInExecutionGate() {
        let policy = MeetingPolicy(objective: "試作アプリを作る", autoBuild: false, maxJobs: 3)
        let candidate = BuildCandidate(topic: "プロトタイプ", origin: "voice_tool")
        let evaluation = ExecutionGate.evaluate(candidate: candidate, policy: policy, activeJobID: nil, totalJobs: 0)
        // autoBuildがfalseの場合、voice_toolからの提案はdeferredになること
        expectEqual(evaluation.decision, GateDecision.deferred)
    }

    /// AG.md要件: iPhoneから来た文字起こし（.mobile）も共通イベントとしてルーターで正しく処理されること
    func testMobileAudioSourceRouteProcessing() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "ライフログアプリを作る", autoBuild: true, maxJobs: 3)
        let ev = TranscriptEvent(text: "サイドキック、今の議論についてどう思う？", source: .mobile, isFinal: true, timestamp: now)
        let judgment = Judgment(wakeScore: 1.0, speakScore: 0.85, topic: "意見伺い")
        let actions = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(actions.contains(where: { $0.action == .wake }))
    }

    /// 停止時にrouter.reset()により状態が正しく初期化されること
    func testRouterResetClearsThrottlingAndProcessedEvents() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "テスト", autoBuild: true, maxJobs: 3)
        let ev = event("メモアプリを作って")
        let judgment = Judgment(buildScore: 0.95, topic: "メモアプリ")

        let actions1 = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(actions1.contains(where: { $0.action == .build }))

        // 同じイベントはリプレイ防止で2回目は空
        let actions2 = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(actions2.isEmpty)

        // reset後は再度受付可能になること
        router.reset()
        let actions3 = router.route(event: ev, judgment: judgment, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(actions3.contains(where: { $0.action == .build }))
    }

    /// 指摘事項4: 制作ジョブ進行中 (activeJobID != nil) の場合、直列実行原則に基づき ExecutionGate が新規ジョブを .deferred（保留）にすること
    func testExecutionGateDefersWhenActiveJobIsRunning() {
        let policy = MeetingPolicy(objective: "議事録ツールを作る", autoBuild: true, maxJobs: 3)
        let candidate = BuildCandidate(topic: "議事録検索機能", origin: "auto_idea")

        // 実行中ジョブがない場合は approved
        let evalFree = ExecutionGate.evaluate(candidate: candidate, policy: policy, activeJobID: nil, totalJobs: 0)
        expectEqual(evalFree.decision, GateDecision.approved)

        // 実行中ジョブがある場合は deferred（直列実行原則）
        let evalBusy = ExecutionGate.evaluate(candidate: candidate, policy: policy, activeJobID: "job-123", totalJobs: 1)
        expectEqual(evalBusy.decision, GateDecision.deferred)
        expectTrue(evalBusy.reason.contains("実行中"))
    }

    /// 指摘事項4: doNotBuildCriteria の多面的照合（全文部分一致および核となるトークン照合）
    func testExecutionGateMultiFacetedDoNotBuildMatching() {
        let policy = MeetingPolicy(
            objective: "業務自動化ツール",
            autoBuild: true,
            maxJobs: 3,
            doNotBuildCriteria: ["決済API連携", "ユーザー認証基盤"]
        )

        // 部分一致
        let c1 = BuildCandidate(topic: "Stripe決済API連携の試作", origin: "auto_idea")
        let eval1 = ExecutionGate.evaluate(candidate: c1, policy: policy, activeJobID: nil, totalJobs: 0)
        expectEqual(eval1.decision, GateDecision.rejected)

        // トークン一致（"決済"）
        let c2 = BuildCandidate(topic: "月額課金と決済のモックアップ", origin: "auto_idea")
        let eval2 = ExecutionGate.evaluate(candidate: c2, policy: policy, activeJobID: nil, totalJobs: 0)
        expectEqual(eval2.decision, GateDecision.rejected)

        // 該当しないものは通過
        let c3 = BuildCandidate(topic: "日報集計ダッシュボード", origin: "auto_idea")
        let eval3 = ExecutionGate.evaluate(candidate: c3, policy: policy, activeJobID: nil, totalJobs: 0)
        expectEqual(eval3.decision, GateDecision.approved)
    }

    /// 指摘事項2: 本文中に「プロトタイプ」「作るべき」「推奨」などのキーワードがあっても、構造化出力（recommend_build: false）なら制作を開始しないこと
    func testThoughtRecommendationRejectsBuildEvenWithDiscussionKeywords() {
        let textWithFalseJson = """
        設計の検討メモ:
        チーム内では「プロトタイプを今すぐ作るべき」という意見や、
        「先行してプロトタイプ実装を推奨する」という声もありましたが、
        セキュリティ要件とデータストアの選定が未確定なため、実装に着手するのは危険です。
        まずは要件定義を詰めることを強く推奨します。

        ```json
        {
          "recommend_build": false,
          "decision_reason": "データストア選定が未確定のため安全に見送り"
        }
        ```
        """

        let recFalse = ThoughtRecommendation.parse(from: textWithFalseJson)
        expectFalse(recFalse.recommend_build)
        expectEqual(recFalse.decision_reason, "データストア選定が未確定のため安全に見送り")

        let textWithTrueJson = """
        検討結果:
        要件が明確であり、画面設計も合意が取れています。
        プロトタイプを実装して検証することを推奨します。

        ```json
        {
          "recommend_build": true,
          "decision_reason": "合意済みのため即座にプロトタイプ作成を推奨"
        }
        ```
        """

        let recTrue = ThoughtRecommendation.parse(from: textWithTrueJson)
        expectTrue(recTrue.recommend_build)
        expectEqual(recTrue.decision_reason, "合意済みのため即座にプロトタイプ作成を推奨")
    }

    /// 指摘事項3: 構造化JSON（recommend_build）が取得できない場合は常に fail-closed（recommend_build = false）となること
    func testThoughtRecommendationFailsClosedWithoutValidJson() {
        // テキスト内に「recommend_build: 進める」や「試作判定: 着手」と書かれていても構造化JSONがないため false
        let textWithTextFallback = """
        思考メモ:
        このアイデアは良さそうです。
        recommend_build: 進める
        試作判定: 着手
        """
        let rec1 = ThoughtRecommendation.parse(from: textWithTextFallback)
        expectFalse(rec1.recommend_build)
        expectTrue(rec1.decision_reason.contains("fail-closed"))

        // JSONが壊れている場合
        let textWithBrokenJson = """
        ```json
        { "recommend_build": NOT_A_BOOL }
        ```
        """
        let rec2 = ThoughtRecommendation.parse(from: textWithBrokenJson)
        expectFalse(rec2.recommend_build)

        // 空文字や通常テキスト
        let rec3 = ThoughtRecommendation.parse(from: "普通の思考メモです。")
        expectFalse(rec3.recommend_build)
    }

    /// 指摘事項2: セッション間での要約クールダウンリセットの検証
    /// セッションAで要約実行後、セッションリセットすれば直後でもセッションBで要約が受け付けられること
    func testSummaryCooldownResetPerSession() {
        var tracker = SummaryCooldownTracker(cooldownSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 100_000)

        // 1. セッションAでJEV要約トリガーを許可
        let allow1 = tracker.shouldAllowSummary(now: t0)
        expectTrue(allow1)

        // 2. 直後（10秒後、60秒以内）はクールダウンにより抑制される
        let allow2 = tracker.shouldAllowSummary(now: t0.addingTimeInterval(10))
        expectFalse(allow2)

        // 3. セッションリセット実行（resetSession: lastSummaryAt = .distantPast）
        tracker.resetSession()
        expectEqual(tracker.lastSummaryAt, Date.distantPast)

        // 4. セッションBでは直後（10秒後のタイムスタンプ）でも要約トリガーを受け付けられること
        let allow3 = tracker.shouldAllowSummary(now: t0.addingTimeInterval(10))
        expectTrue(allow3)
    }

    /// 指摘事項1: wake と think の同時発火ポリシーの検証
    /// 1. 通常の名前呼び・短い意見質問（「どう思う？」等）では wake 優先となり、think は同時発火しないこと
    func testWakeVsThinkPolicy_NormalOpinionQuestionOnlyWakes() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(nickname: "サイドキック")
        let ev = event("サイドキック、今の議論どう思う？")
        // JEVがwakeとthinkの両方に高いスコアを返した場合
        let j = Judgment(wakeScore: 0.9, thinkScore: 0.85, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.wake])
    }

    /// 2. 名前を呼びながら明示的に「深く考えて」「比較して」等を要求した場合は wake + think の両方を許可すること
    func testWakeVsThinkPolicy_ExplicitDeepThinkingAllowsBothWakeAndThink() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(nickname: "サイドキック")
        let ev = event("サイドキック、この2つの案について深く比較検討して")
        let j = Judgment(wakeScore: 0.9, thinkScore: 0.85, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.wake, .think])
    }

    /// 3. 名前呼びなしで思考のみを要求した場合は think のみとなること
    func testWakeVsThinkPolicy_NoWakeDeepThinkingOnlyThinks() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(nickname: "サイドキック")
        let ev = event("この案についてメリットと問題点を比較して考えて")
        let j = Judgment(wakeScore: 0.1, thinkScore: 0.85, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.think])
    }

    /// 用語調査の判定テスト
    func testDecisionRouterRoutesResearchTermWhenScoreHigh() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("OCuLinkの帯域について議論しましょう")
        let j = Judgment(termResearchScore: 0.85)
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.researchTerm])
        expectEqual(actions.first?.evidenceID, ev.id)
    }

    func testDecisionRouterDoesNotRouteResearchTermWhenScoreLow() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("普通に挨拶しましょう")
        let j = Judgment(termResearchScore: 0.3)
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectTrue(actions.isEmpty)
    }

    func testResearchTermCanCoexistWithWakeAndBuild() {
        var router = DecisionRouter()
        let policy = MeetingPolicy(objective: "GPU接続ツール", autoBuild: true)
        let ev = event("サイドキック、OCuLink対応の管理ツールを作って")
        let j = Judgment(wakeScore: 1.0, buildScore: 1.0, termResearchScore: 0.9)
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.wake, .build, .researchTerm])
    }

    func testStopOverridesResearchTerm() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("作業を全部止めて")
        let j = Judgment(stopScore: 1.0, termResearchScore: 0.9)
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.stop])
    }

    /// 「eGPUならOCuLinkかな」のような発話で、明示的な深い思考要求がない場合は think が抑止され researchTerm のみ発火する検証
    func testResearchTermSuppressesThinkWithoutDeepThinking() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("eGPUならOCuLinkかな")
        let j = Judgment(thinkScore: 0.85, termResearchScore: 0.85, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.researchTerm])
    }

    /// 「eGPUならOCuLinkについて深く検討して」のように明示的な深い思考要求がある場合は think と researchTerm の両方が発火する検証
    func testResearchTermAllowsThinkWhenDeepThinkingRequested() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("eGPUならOCuLinkについて深く検討して")
        let j = Judgment(thinkScore: 0.85, termResearchScore: 0.85, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.think, .researchTerm])
    }

    /// Judgment側で requestsDeepThinking == true が立っている場合に think と researchTerm の両方が発火する検証
    func testResearchTermAllowsThinkWhenJudgmentRequestsDeepThinking() {
        var router = DecisionRouter()
        let policy = MeetingPolicy()
        let ev = event("eGPUならOCuLinkかな")
        let j = Judgment(thinkScore: 0.85, termResearchScore: 0.85, requestsDeepThinking: true, thinkMode: "think_only")
        let actions = router.route(event: ev, judgment: j, policy: policy, activeJobID: nil, totalJobs: 0, now: now)
        expectEqual(actions.map(\.action), [.think, .researchTerm])
    }
}
