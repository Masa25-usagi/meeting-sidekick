import Foundation

private var failureCount = 0
func report(_ condition: Bool, _ message: String, file: StaticString, line: UInt) {
    if !condition { failureCount += 1; print("FAIL \(file):\(line) \(message)") }
}
func expectTrue(_ v: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { report(v(), "expected true", file: file, line: line) }
func expectFalse(_ v: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { report(!v(), "expected false", file: file, line: line) }
func expectEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) { report(a() == b(), "values differ", file: file, line: line) }
func expectNotNil<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) { report(v != nil, "expected nonnil", file: file, line: line) }
func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { report(a > b, "expected greater value", file: file, line: line) }
func expectLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { report(a <= b, "expected bounded value", file: file, line: line) }
func expectThrows<T>(_ block: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try block(); report(false, "expected error", file: file, line: line) } catch {} }
func expectNoThrow<T>(_ block: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try block() } catch { report(false, "unexpected error", file: file, line: line) } }

@main
struct CheckRunner {
    @MainActor
    static func main() async throws {
        let core = DecisionTests()
        core.testPartialThenFinalAndDuplicate(); core.testNegationOverridesWrongModel()
        core.testStopIgnoresBudgetAndCooldown(); core.testAssistantAndStaleAreNotActions()
        core.testWakeAndBuildCanHappenTogetherButNotDoubleVoice(); core.testLocalIdeaAndNegatedStop()
        core.testContextDoesNotOverwriteFinalWithLatePartial(); core.testNonfiniteScoresFailClosed()
        core.testAcceptanceCondition1_AutoBuildWithoutExplicitCommand()
        core.testAcceptanceCondition2_WakeAndNoSelfReaction()
        core.testAcceptanceCondition3_NegationAndDuplicateRejection()
        core.testAcceptanceCondition4_StaleUtterancesDropped()
        core.testAcceptanceCondition5_ModifyAndImmediateStop()
        core.testCriteriaRespectsDoNotBuild()
        core.testCriteriaTriggersCustomBuild()
        core.testCriteriaTriggersCustomSpeak()
        core.testAcceptanceCondition9_JevThinkActionDoesNotTriggerBuildJob()
        core.testLocalRuleJudgeDetectsThinkingRequest()
        core.testThinkVsBuildPriorityWhenBothScoresHighWithoutExplicitCommand()
        core.testVoiceToolCannotBypassAutoBuildPolicyInExecutionGate()
        core.testMobileAudioSourceRouteProcessing()
        core.testRouterResetClearsThrottlingAndProcessedEvents()
        core.testExecutionGateDefersWhenActiveJobIsRunning()
        core.testExecutionGateMultiFacetedDoNotBuildMatching()
        core.testThoughtRecommendationRejectsBuildEvenWithDiscussionKeywords()
        core.testThoughtRecommendationFailsClosedWithoutValidJson()
        core.testSummaryCooldownResetPerSession()
        core.testWakeVsThinkPolicy_NormalOpinionQuestionOnlyWakes()
        core.testWakeVsThinkPolicy_ExplicitDeepThinkingAllowsBothWakeAndThink()
        core.testWakeVsThinkPolicy_NoWakeDeepThinkingOnlyThinks()
        core.testDecisionRouterRoutesResearchTermWhenScoreHigh()
        core.testDecisionRouterDoesNotRouteResearchTermWhenScoreLow()
        core.testResearchTermCanCoexistWithWakeAndBuild()
        core.testStopOverridesResearchTerm()
        core.testResearchTermSuppressesThinkWithoutDeepThinking()
        core.testResearchTermAllowsThinkWhenDeepThinkingRequested()
        core.testResearchTermAllowsThinkWhenJudgmentRequestsDeepThinking()

        let wire = ProtocolTests()
        try wire.testGeminiDoesNotPlaceKeyInURL(); try wire.testSetupUsesAudioAndBoundedCompression()
        try wire.testInterruptionDropsAudio(); try wire.testAudioAndImageValidation(); try wire.testJevStrictScores()
        try wire.testGeminiSetupIncludesPrototypeTool(); try wire.testGeminiParsesToolCallAndGeneratesToolResponse()
        try wire.testOpenAIRealtimeWireRequestAndHeaders(); try wire.testOpenAIRealtimeSessionUpdateAndEvents()
        try wire.testContextIngestorParsesSynthesizedRules()
        try wire.testStrictRuleValidationRejectsInvalidOutput()
        try wire.testOpenAIResamplerRatioAndContinuity()
        try wire.testPCM16StreamingResamplerChunkContinuity()
        try await wire.testCLIDrainsLargeStderrWithoutDeadlock()
        try await wire.testCLITimeout()
        try wire.testContextIngestorScansProjectFiles()
        try wire.testCLIExecutableResolution()
        try await wire.testMobileLogReceiverAuthentication()
        try wire.testJevSummaryScoreAndTrigger()
        try await wire.testDelayedJevResponseDiscardedOnSessionResetOrStopWork()
        try await wire.testProviderSwitchSafety()
        try wire.testJevTermResearchScoreParsing()
        wire.testTerminologyExtraction()
        try await wire.testMeetingRuntimeResearchDeduplicationAndFailSilent()
        wire.testTerminologyResearchModelAndSearchSettings()
        try await wire.testInFlightTermsPreventsParallelDuplicateExecution()
        try await wire.testDoubleDefenseAgainstGenericTerms()
        try await wire.testWakeAndResearchTermDoNotBlockVoiceSession()
        try wire.testResearchSourceSecurityAndSanitization()
        try await wire.testTerminologyResearchQueueLimitsConcurrencyToOne()
        try await wire.testWakeDuringActiveResearchQueueDoesNotBlockVoice()
        wire.testCLIEnvironmentAugmentedPathPreservesExistingAndDeduplicates()
        try await wire.testCLIRunsCodexWithMinimalGUIPath()
        wire.testContextualStringsConstructionAndDeduplication()
        wire.testCLISanitizesStderrDiagnostics()
        wire.testCodexArgumentsWorkingDirectoryAndSkipGitRepoCheck()
        try await wire.testCodexAppServerParametersAndSmartModelResolution()
        try await wire.testCodexAppServerStrictSolFallback()
        try await wire.testCodexAppServerWebSearchSchemaLiveAndDisabled()
        try await wire.testCodexAppServerSerializesConcurrentTurns()
        try await wire.testCodexAppServerRestartCountResetOnSuccess()
        try await wire.testCodexAppServerFallbackToExecOnFailure()
        try await wire.testThinkingExecutionFailureSetsCleanBannerErrorMessageAndDetailsDiagnostic()
        wire.testSpeechTranscriptionSelectorPrioritizesDomainVocabulary()
        wire.testSpeechTranscriptionSelectorConservativeSelection()
        wire.testResearchNoteDiagnosticsSummary()
        try wire.testTranscriptEventRawAndNormalizedSeparation()
        wire.testCustomLanguageModelHelperSupport()
        try await wire.testCodexAppServerTurnWaitCancellation()
        try await wire.testResetSessionAndBackendTerminateIsolation()
        try await wire.testCustomLanguageModelPrewarmAndCache()
        try await wire.testCustomLanguageModelImmediateAndPrewarmApplicationToFirstRequest()
        try await wire.testCodexExecBackendWebSearchUsedIsUnknown()

        runVoiceCommandChecks()
        try await runCredentialLoaderChecks()
        try await runCLMRegressionChecks()
        try await runLiveAudioChecks()
        try await runRuntimeRegressionChecks()
        let backendChecks = CodexBackendRegressionChecks()
        try await backendChecks.testSilentServerTimeoutDoesNotRetryOrFallback()
        try await backendChecks.testActiveCancellationStopsPipeWaitAndAllowsNextTurn()
        try await backendChecks.testQueuedCancellationAndTimeoutDoNotStopOwner()
        try await backendChecks.testSearchEventsAreScopedAndURLsComeFromHostResults()
        try await backendChecks.testMissingSearchTelemetryRemainsUnknown()
        try await backendChecks.testStaleTerminationDoesNotKillNewGeneration()
        try await backendChecks.testSemanticErrorsDoNotRetryOrEscapeModelPolicy()
        try await backendChecks.testOneDeadlineCoversStartupAndTurn()
        try await backendChecks.testBlockedInputPipeHonorsTimeout()
        print("Regression suite completed; \(failureCount) failures")
        if failureCount > 0 { exit(1) }
    }
}
