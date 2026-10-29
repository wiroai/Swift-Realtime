import XCTest
@testable import SwiftRealtime

final class TextToSpeechSessionServiceTests: XCTestCase {
    func testRequiresNonEmptyTrimmedText() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "   "

        await service.start()

        XCTAssertEqual(dependencies.apiClient.runCalls, 0)
        XCTAssertTrue(dependencies.audioSession.preparedProfiles.isEmpty)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertEqual(
            service.snapshot.errorMessage,
            TextToSpeechSessionService.emptyPromptMessage,
        )
        await service.dispose()
    }

    func testRunsMossWithTextAndPreparesPlayback() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "  Hello realtime speech.  "

        await service.start()

        XCTAssertEqual(
            dependencies.audioSession.preparedProfiles,
            [.speech],
        )
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?["text"] as? String,
            "Hello realtime speech.",
        )
        XCTAssertEqual(dependencies.session.connectCalls, 1)
        XCTAssertEqual(dependencies.player.startCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        await service.dispose()
    }

    func testSelectsInactiveTTSModelsAndChangesThePromptField()
        async
    {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()

        service.selectModel(WiroModelCatalog.voxcpm2)
        service.prompt = "Vox prompt"
        await service.start()

        XCTAssertEqual(
            service.snapshot.selectedModel,
            WiroModelCatalog.voxcpm2,
        )
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?["prompt"]
                as? String,
            "Vox prompt",
        )
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?["cfgValue"]
                as? Double,
            2.0,
        )
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?["inferenceSteps"]
                as? Int,
            10,
        )
        await service.dispose()
    }

    func testReselectingTheModelResetsItsParameterValues() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Discard me"

        service.selectModel(WiroModelCatalog.mossTtsRealtime)

        XCTAssertTrue(service.prompt.isEmpty)
        await service.dispose()
    }

    func testRejectsModelChangesWhileActiveOrInAnotherDirection()
        async
    {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()

        service.selectModel(WiroModelCatalog.voxtralMiniRealtime)
        XCTAssertEqual(
            service.snapshot.selectedModel.direction,
            .textToSpeech,
        )
        service.prompt = "Hello"
        await service.start()
        service.selectModel(WiroModelCatalog.voxcpm2)

        XCTAssertEqual(
            service.snapshot.selectedModel.modelSlug,
            WiroModelCatalog.mossTtsRealtime.modelSlug,
        )
        await service.dispose()
    }

    func testResubscribesToATaskTheSocketDroppedWhileSpinningUp()
        async
    {
        let dependencies = SpeechTestDependencies(
            sessionConnectFailures: 2,
        )
        let service = dependencies.createService()
        service.prompt = "Hello"

        await service.start()

        XCTAssertEqual(dependencies.session.connectCalls, 3)
        XCTAssertTrue(dependencies.apiClient.terminatedTaskIds.isEmpty)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertTrue(
            service.protocolEvents
                .contains("socket_reconnect:1"),
        )
        await service.dispose()
    }

    func testATaskThatNeverStreamsFailsOnceTheRetryBudgetIsSpent()
        async
    {
        let dependencies = SpeechTestDependencies(
            sessionConnectFailures: 99,
        )
        let service = dependencies.createService()
        service.prompt = "Hello"

        await service.start()

        XCTAssertEqual(dependencies.session.connectCalls, 8)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertEqual(
            dependencies.apiClient.terminatedTaskIds,
            ["task-id"],
        )
        await service.dispose()
    }

    func testQueuesPCMInFIFOAndDrainsBeforeNaturalCompletion()
        async
    {
        let dependencies = SpeechTestDependencies(holdComplete: true)
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        dependencies.session.emit(.binary(Data([1, 2])))
        dependencies.session.emit(.binary(Data([3, 4])))
        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.status(.postprocessEnded))
        await waitUntil {
            service.snapshot.sessionState == .stopping
        }
        // The drain runs on its own task. Releasing it before it
        // waits finds no gate, and the release is lost.
        await waitUntil { dependencies.player.isHoldingComplete }

        XCTAssertEqual(
            dependencies.player.fedChunks,
            [Data([1, 2]), Data([3, 4])],
        )
        XCTAssertTrue(service.snapshot.isPlaying)
        XCTAssertEqual(service.snapshot.sessionState, .stopping)

        dependencies.player.releaseComplete()
        await waitUntil {
            service.snapshot.sessionState == .completed
        }
        XCTAssertFalse(service.snapshot.isPlaying)
        XCTAssertEqual(dependencies.player.completeCalls, 1)
        await service.dispose()
    }

    func testEarlyStopFlushesPlaybackAndEndsOnce() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()
        dependencies.session.emit(.binary(Data([1, 2])))

        async let firstStop: Void = service.stop()
        async let secondStop: Void = service.stop()
        _ = await (firstStop, secondStop)

        XCTAssertEqual(dependencies.player.stopCalls, 1)
        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        XCTAssertEqual(dependencies.session.closeCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        await service.dispose()
    }

    func testMapsPlaybackFailuresToASanitizedFailure() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        dependencies.player.emitFailure()
        await waitUntil {
            service.snapshot.sessionState == .failure
        }

        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertFalse(
            service.snapshot.errorMessage?.contains("platform")
                ?? true,
        )
        await service.dispose()
    }

    func testRejectsMalformedRealtimeAudioFrames() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        dependencies.session.emit(.malformed)
        await waitUntil {
            service.snapshot.sessionState == .failure
        }

        XCTAssertEqual(service.snapshot.sessionState, .failure)
        await service.dispose()
    }

    func testCancelsPendingRunAndTerminatesAStaleResult() async {
        let dependencies = SpeechTestDependencies()
        dependencies.apiClient.holdRunModel = true
        let service = dependencies.createService()
        service.prompt = "Hello"
        let starting = Task { await service.start() }
        await dependencies.apiClient.waitUntilHolding()

        let stopping = Task { await service.stop() }
        await waitUntil {
            dependencies.apiClient.lastCancellation?.isCancelled
                == true
        }
        dependencies.apiClient.completeRunModel()
        await starting.value
        await stopping.value

        XCTAssertEqual(
            dependencies.apiClient.terminatedTaskIds,
            ["task-id"],
        )
        XCTAssertEqual(dependencies.session.connectCalls, 0)
        await service.dispose()
    }

    func testASlowShutdownConfirmationCompletesWithoutAnError()
        async
    {
        let dependencies = SpeechTestDependencies(
            completeSessionEnd: false,
        )
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        await service.stop()

        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertNil(service.snapshot.errorMessage)
        XCTAssertTrue(
            service.protocolEvents
                .contains("shutdown_timeout"),
        )
        await service.dispose()
    }

    func testStopsAnActiveSessionOnInterruption() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        dependencies.audioSession.emitInterruption(.began)
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        await service.dispose()
    }

    func testKeepsProtocolHistoryBounded() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        for index in 0..<50 {
            dependencies.session.emit(
                .unknown(wireType: "future_event_\(index)"),
            )
        }

        XCTAssertEqual(service.protocolEvents.count, 40)
        await service.dispose()
    }

    func testCommandsAfterDisposeAreSafeNoOps() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        await service.dispose()
        let snapshot = service.snapshot

        service.selectModel(WiroModelCatalog.voxcpm2)
        await service.start()
        await service.stop()

        XCTAssertEqual(dependencies.apiClient.runCalls, 0)
        XCTAssertEqual(service.snapshot, snapshot)
    }

    func testStartAfterDisposeDoesNotStrandTheSharedLease() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        await service.dispose()

        await service.start()

        XCTAssertNotNil(
            dependencies.sessionGuard.acquire(.conversation),
        )
    }

    func testStreamAndPostprocessRacingStopRemainIdempotent() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        await service.start()

        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.status(.postprocessEnded))
        // Let the stream end reach the player first, so the stop
        // below races the natural completion rather than pre-empting
        // it — the former is the idempotency this test is about.
        await waitUntil { dependencies.player.completeCalls == 1 }
        await service.stop()
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertEqual(dependencies.session.closeCalls, 1)
        XCTAssertEqual(dependencies.player.completeCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        await service.dispose()
    }

    func testAStartDuringAnotherFeatureTeardownWaitsItOut() async {
        let dependencies = SpeechTestDependencies()
        let service = dependencies.createService()
        service.prompt = "Hello"
        let departing = dependencies.sessionGuard.acquire(
            .conversation,
        )

        let starting = Task { await service.start() }
        await waitUntil {
            service.snapshot.sessionState == .preparingAudio
        }
        dependencies.sessionGuard.release(departing)
        await starting.value

        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertNil(service.snapshot.errorMessage)
        await service.dispose()
    }
}
