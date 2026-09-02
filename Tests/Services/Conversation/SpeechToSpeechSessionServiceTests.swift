import os
import XCTest
@testable import SwiftRealtime

final class SpeechToSpeechSessionServiceTests: XCTestCase {
    func testStartsGPTRealtimeWithVerifiedPCMParameters() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()

        await service.start()

        XCTAssertEqual(
            dependencies.audioSession.preparedProfiles,
            [.conversation],
        )
        XCTAssertEqual(
            stringParam(dependencies, "input_audio_format"),
            "audio/pcm",
        )
        XCTAssertEqual(
            stringParam(dependencies, "output_audio_format"),
            "audio/pcm",
        )
        XCTAssertEqual(
            stringParam(dependencies, "input_audio_rate"),
            "24000",
        )
        XCTAssertEqual(
            stringParam(dependencies, "output_audio_rate"),
            "24000",
        )
        XCTAssertEqual(dependencies.recorder.startCalls, 1)
        XCTAssertEqual(dependencies.player.startCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertTrue(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testSendsTheConfiguredPersonaAndVoice() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()

        await service.start()

        XCTAssertEqual(
            stringParam(dependencies, "system_instructions"),
            ConversationConfig.persona,
        )
        XCTAssertEqual(
            stringParam(dependencies, "voice"),
            ConversationConfig.voice,
        )
        await service.dispose()
    }

    func testAConversationLeftOpenEndsItselfAtTheCeiling() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            maxSessionDuration: .seconds(1),
        )
        await service.start()

        try? await Task.sleep(for: .milliseconds(1_400))

        XCTAssertTrue(
            service.protocolEvents
                .contains("session_limit_reached"),
        )
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        await service.dispose()
    }

    func testAZeroCeilingLetsTheConversationRunOn() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            maxSessionDuration: .zero,
        )
        await service.start()

        try? await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        await service.dispose()
    }

    func testStreamsMicrophoneAndAssistantPCMConcurrently() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.recorder.emit(Data([1, 2]))
        dependencies.session.emit(.binary(Data([3, 4])))
        await waitUntil {
            dependencies.session.sentAudio.count == 1
        }

        XCTAssertEqual(dependencies.session.sentAudio, [Data([1, 2])])
        XCTAssertEqual(dependencies.player.fedChunks, [Data([3, 4])])
        await service.dispose()
    }

    func testKeepsMicrophoneStreamingWhileTheAIIsSpeaking() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data([3, 4])))
        dependencies.recorder.emit(Data([5]))
        await waitUntil {
            dependencies.session.sentAudio.count == 1
        }

        XCTAssertEqual(dependencies.session.sentAudio, [Data([5])])
        XCTAssertTrue(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testAUserTranscriptAloneNeverCutsAssistantAudio() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data([1])))
        dependencies.session.emit(.output("TRANSCRIPT_USER:Stop"))
        dependencies.session.emit(.binary(Data([2])))

        XCTAssertEqual(dependencies.player.flushCalls, 0)
        XCTAssertEqual(dependencies.player.stopCalls, 0)
        XCTAssertEqual(
            dependencies.player.fedChunks,
            [Data([1]), Data([2])],
        )
        XCTAssertEqual(service.snapshot.userTranscript, "Stop")
        await service.dispose()
    }

    func testANewAssistantTurnDropsTheInterruptedTurnTail() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data([1])))
        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.binary(Data([2])))
        dependencies.session.emit(.binary(Data([3])))

        XCTAssertEqual(dependencies.player.flushCalls, 1)
        XCTAssertEqual(
            dependencies.player.fedChunks,
            [Data([2]), Data([3])],
        )
        XCTAssertTrue(
            service.protocolEvents
                .contains("previous_turn_dropped"),
        )
        await service.dispose()
    }

    func testInterruptAssistantCutsTheTurnAndKeepsTheNext() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data(count: 48_000)))
        service.interruptAssistant()

        XCTAssertEqual(dependencies.player.flushCalls, 1)
        XCTAssertTrue(
            service.protocolEvents
                .contains("assistant_silenced_by_user"),
        )

        dependencies.session.emit(.binary(Data([9])))
        XCTAssertTrue(dependencies.player.fedChunks.isEmpty)

        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.binary(Data([7])))
        XCTAssertEqual(dependencies.player.fedChunks, [Data([7])])
        await service.dispose()
    }

    func testTheUsersTranscriptReleasesACutTurnSoTheNewAnswerIsHeard() async {
        // The server transcribing the interruption proves it heard it
        // and moved on; a `task_stream_end` for the cut turn is not
        // guaranteed before the new answer's audio.
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data(count: 48_000)))
        service.interruptAssistant()
        dependencies.session.emit(.binary(Data([9])))
        XCTAssertTrue(dependencies.player.fedChunks.isEmpty)

        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Wait, what about tomorrow?"),
        )
        dependencies.session.emit(.binary(Data([7])))
        dependencies.session.emit(.binary(Data([8])))

        XCTAssertEqual(
            dependencies.player.fedChunks,
            [Data([7]), Data([8])],
        )
        XCTAssertTrue(
            service.protocolEvents
                .contains("interrupted_turn_released"),
        )
        await service.dispose()
    }

    func testAFreshAssistantTranscriptReleasesACutTurn() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.output("TRANSCRIPT_AI:Once upon a"))
        dependencies.session.emit(.binary(Data(count: 48_000)))
        service.interruptAssistant()

        dependencies.session.emit(.output("TRANSCRIPT_AI:Tomorrow looks"))
        dependencies.session.emit(.binary(Data([7])))

        XCTAssertEqual(dependencies.player.fedChunks, [Data([7])])
        XCTAssertEqual(service.snapshot.aiTranscript, "Tomorrow looks")
        await service.dispose()
    }

    func testTheCutTurnsOwnTranscriptKeepsItSilenced() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.output("TRANSCRIPT_AI:Once upon a"))
        dependencies.session.emit(.binary(Data(count: 48_000)))
        service.interruptAssistant()

        dependencies.session.emit(
            .output("TRANSCRIPT_AI:Once upon a time there was"),
        )
        dependencies.session.emit(.binary(Data([9])))

        XCTAssertTrue(dependencies.player.fedChunks.isEmpty)
        XCTAssertFalse(
            service.protocolEvents
                .contains("interrupted_turn_released"),
        )
        await service.dispose()
    }

    func testInterruptAssistantWithNothingPlayingNeverLatches() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        service.interruptAssistant()
        XCTAssertEqual(dependencies.player.flushCalls, 0)

        dependencies.session.emit(.binary(Data([1])))
        XCTAssertEqual(dependencies.player.fedChunks, [Data([1])])
        await service.dispose()
    }

    func testTheFirstSignOfUserSpeechHoldsPlaybackWithoutCommitting() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data(count: 48_000)))
        for _ in 0..<3 {
            dependencies.recorder.emit(
                conversationPcm(amplitude: 20_000),
            )
        }
        await waitUntil {
            service.protocolEvents
                .contains("assistant_playback_held")
        }

        XCTAssertEqual(dependencies.player.flushCalls, 1)
        XCTAssertFalse(
            service.protocolEvents
                .contains("assistant_interrupted"),
        )

        // A held turn keeps its audio queued rather than fed, so a
        // brief loud burst never actually loses the answer.
        dependencies.session.emit(.binary(Data([9])))
        XCTAssertTrue(dependencies.player.fedChunks.isEmpty)
        await service.dispose()
    }

    func testSustainedSpeechOverTheAssistantCommitsTheCut() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data(count: 48_000)))
        for _ in 0..<8 {
            dependencies.recorder.emit(
                conversationPcm(amplitude: 20_000),
            )
        }
        await waitUntil {
            service.protocolEvents
                .contains("assistant_interrupted")
        }

        // Confirmed, unlike a hold: further audio for the cut turn
        // stays silenced rather than coming back.
        dependencies.session.emit(.binary(Data([9])))
        XCTAssertTrue(dependencies.player.fedChunks.isEmpty)
        await service.dispose()
    }

    func testAssignsProgressiveTranscriptsToTheCorrectRole() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.output("TRANSCRIPT_USER:Hello"))
        dependencies.session.emit(.output("TRANSCRIPT_AI:Hi there"))
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Hello world"),
        )

        XCTAssertEqual(service.snapshot.userTranscript, "Hello world")
        XCTAssertEqual(service.snapshot.aiTranscript, "Hi there")
        await service.dispose()
    }

    func testMuteDropsMicrophoneAudioWithoutClosingTheSession() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        service.setMuted(true)
        dependencies.recorder.emit(Data([1]))
        service.setMuted(false)
        dependencies.recorder.emit(Data([2]))
        await waitUntil {
            dependencies.session.sentAudio.count == 1
        }

        XCTAssertEqual(dependencies.session.sentAudio, [Data([2])])
        XCTAssertEqual(dependencies.session.closeCalls, 0)
        XCTAssertTrue(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testStopReleasesAllMediaAndSendsOneSessionEnd() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        async let firstStop: Void = service.stop()
        async let secondStop: Void = service.stop()
        _ = await (firstStop, secondStop)

        XCTAssertEqual(dependencies.recorder.stopCalls, 1)
        XCTAssertEqual(dependencies.player.stopCalls, 1)
        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        XCTAssertEqual(dependencies.session.closeCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertFalse(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testAITurnEndResumesListeningWithoutClosing() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()
        dependencies.session.emit(.binary(Data([1, 2])))

        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.status(.ended))

        XCTAssertEqual(dependencies.player.completeCalls, 0)
        XCTAssertEqual(dependencies.player.startCalls, 1)
        XCTAssertEqual(dependencies.player.fedChunks, [Data([1, 2])])
        XCTAssertEqual(dependencies.recorder.stopCalls, 0)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertTrue(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testPostprocessEndDrainsMediaAndCompletesTheSession() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.status(.postprocessEnded))
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertEqual(dependencies.player.completeCalls, 1)
        XCTAssertEqual(dependencies.recorder.stopCalls, 1)
        await service.dispose()
    }

    func testARemoteTaskEndCostsNothingMore() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(50),
        )
        await service.start()

        dependencies.session.emit(.status(.postprocessEnded))
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertTrue(
            service.protocolEvents
                .contains("conversation_ended_remotely"),
        )

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        await service.dispose()
    }

    func testAUserStopNeverRestartsByItself() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(20),
        )
        await service.start()

        await service.stop()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertFalse(
            service.protocolEvents
                .contains("conversation_ended_remotely"),
        )
        await service.dispose()
    }

    func testPermissionDenialDoesNotCreateATask() async {
        let dependencies = ConversationTestDependencies(
            preparationResult: .permissionDenied,
        )
        let service = dependencies.createService()

        await service.start()

        XCTAssertEqual(dependencies.apiClient.runCalls, 0)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertNotNil(service.snapshot.errorMessage)
        XCTAssertFalse(service.snapshot.canOpenSystemSettings)
        await service.dispose()
    }

    func testAPermanentlyDeniedMicrophoneOffersSettings() async {
        let dependencies = ConversationTestDependencies(
            preparationResult: .permissionPermanentlyDenied,
        )
        let service = dependencies.createService()

        await service.start()

        XCTAssertTrue(service.snapshot.canOpenSystemSettings)

        await service.openSystemSettings()

        XCTAssertEqual(
            dependencies.audioSession.openSystemSettingsCalls,
            1,
        )
        await service.dispose()
    }

    func testATransportFailureIsNotASettingsProblem() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.snapshot.sessionState == .failure
        }

        XCTAssertNotNil(service.snapshot.errorMessage)
        XCTAssertFalse(service.snapshot.canOpenSystemSettings)
        await service.dispose()
    }

    func testRetriesATransientStartFailureBeforePublishingFailure()
        async
    {
        let dependencies = ConversationTestDependencies(
            runErrors: [WiroFailure.networkUnavailable],
        )
        let service = dependencies.createService(maxRetryAttempts: 2)
        let publishedStates = OSAllocatedUnfairLock(
            initialState: [RealtimeSessionState](),
        )
        let collector = Task {
            for await snapshot in service.snapshots {
                publishedStates.withLock {
                    $0.append(snapshot.sessionState)
                }
            }
        }

        await service.start()

        XCTAssertEqual(dependencies.apiClient.runCalls, 2)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertFalse(
            publishedStates.withLock {
                $0.contains(.failure)
            },
        )
        XCTAssertTrue(
            service.protocolEvents.contains("retry_started:1"),
        )
        collector.cancel()
        await service.dispose()
    }

    func testPublishesFailureOnlyAfterRetriesAreExhausted() async {
        let dependencies = ConversationTestDependencies(
            runErrors: [
                WiroFailure.networkUnavailable,
                WiroFailure.networkUnavailable,
                WiroFailure.networkUnavailable,
            ],
        )
        let service = dependencies.createService(maxRetryAttempts: 2)

        await service.start()

        XCTAssertEqual(dependencies.apiClient.runCalls, 3)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        await service.dispose()
    }

    func testStopsAnActiveSessionWhenAudioIsInterrupted() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.audioSession.emitInterruption(.began)
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        await service.dispose()
    }

    func testAMidStreamSocketFailureReturnsToTheSameTask() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(maxRetryAttempts: 1)
        await service.start()
        dependencies.session.emit(.output("TRANSCRIPT_USER:Hello"))

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.protocolEvents
                .contains("reconnect_accepted")
        }

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(dependencies.apiClient.terminateCalls, 0)
        XCTAssertEqual(
            dependencies.taskTokens,
            ["task-token", "task-token"],
        )
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertEqual(service.snapshot.userTranscript, "Hello")
        await service.dispose()
    }

    func testLeavingSilencesTheMicrophoneAndFreesTheHardware() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            suspendGracePeriod: .seconds(5),
        )
        await service.start()

        await service.suspend()

        XCTAssertTrue(service.snapshot.isSuspended)
        XCTAssertFalse(service.snapshot.microphoneActive)
        XCTAssertFalse(dependencies.recorder.isRecording)
        XCTAssertEqual(dependencies.session.sessionEndCalls, 0)
        XCTAssertEqual(dependencies.apiClient.terminateCalls, 0)
        XCTAssertNotNil(
            dependencies.sessionGuard.acquire(.transcription),
        )
        await service.dispose()
    }

    func testComingBackContinuesTheSameTask() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            suspendGracePeriod: .seconds(5),
        )
        await service.start()
        dependencies.session.emit(.output("TRANSCRIPT_USER:Hello"))
        await service.suspend()

        await service.resume()

        XCTAssertFalse(service.snapshot.isSuspended)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertEqual(service.snapshot.userTranscript, "Hello")
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(
            dependencies.taskTokens,
            ["task-token", "task-token"],
        )
        await service.dispose()
    }

    func testASpeakerWhoNeverComesBackIsHungUpOn() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            suspendGracePeriod: .milliseconds(40),
        )
        await service.start()
        await service.suspend()

        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertFalse(service.snapshot.isSuspended)
        XCTAssertTrue(
            service.protocolEvents.contains("hold_expired"),
        )
        XCTAssertEqual(dependencies.apiClient.terminateCalls, 1)
        await service.dispose()
    }

    func testALapsedHoldIsNotResumedEvenIfTheTimerNeverRan() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            suspendGracePeriod: .milliseconds(20),
        )
        await service.start()
        await service.suspend()
        try? await Task.sleep(for: .milliseconds(60))

        await service.resume()

        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        await service.dispose()
    }

    func testTheConfiguredDefaultEndsTheConversationOutright() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        await service.suspend()

        XCTAssertFalse(service.snapshot.isSuspended)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        await service.dispose()
    }

    func testAnIdleConversationHasNothingToHold() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()

        await service.suspend()
        await service.resume()

        XCTAssertEqual(service.snapshot.sessionState, .idle)
        XCTAssertEqual(dependencies.apiClient.runCalls, 0)
        await service.dispose()
    }

    func testATaskThatRefusesTheReconnectIsReplaced() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(maxRetryAttempts: 1)
        await service.start()
        dependencies.session.connectError = WiroFailure.socketConnection

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.snapshot.sessionState == .streaming
                && dependencies.apiClient.runCalls == 2
        }

        XCTAssertTrue(
            service.protocolEvents
                .contains("reconnect_refused"),
        )
        XCTAssertEqual(dependencies.apiClient.terminateCalls, 1)
        await service.dispose()
    }

    func testADeadMicrophoneReconnectsThenFailsOnceRetriesRunOut()
        async
    {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            maxRetryAttempts: 1,
            micStallTimeout: .milliseconds(60),
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(
            service.protocolEvents
                .contains("microphone_stalled"),
        )
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        await service.dispose()
    }

    func testARecoverableFailureRestartsTheConversationByItself()
        async
    {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(50),
        )
        await service.start()

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.protocolEvents
                .contains("auto_restart_scheduled")
        }

        XCTAssertEqual(service.snapshot.sessionState, .failure)

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(dependencies.apiClient.runCalls, 2)
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        await service.dispose()
    }

    func testLeavingTheScreenCancelsAScheduledRestart() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(50),
        )
        await service.start()

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.protocolEvents
                .contains("auto_restart_scheduled")
        }

        await service.suspend()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        await service.dispose()
    }

    func testABackendThatKeepsRefusingHandsTheOrbBack() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(20),
            maxAutoRestarts: 1,
        )
        await service.start()

        for _ in 0..<4 {
            dependencies.session.emitError(WiroFailure.socketConnection)
            await waitUntil {
                service.snapshot.sessionState == .failure
                    || service.snapshot.sessionState == .streaming
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        XCTAssertEqual(dependencies.apiClient.runCalls, 2)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        await service.dispose()
    }

    func testADeniedPermissionNeverRestartsByItself() async {
        let dependencies = ConversationTestDependencies(
            preparationResult: .permissionDenied,
        )
        let service = dependencies.createService(
            autoRestartDelay: .milliseconds(20),
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(dependencies.apiClient.runCalls, 0)
        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertFalse(
            service.protocolEvents
                .contains("auto_restart_scheduled"),
        )
        await service.dispose()
    }

    func testAFailureReportsWhatHappenedInOneLine() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emitError(WiroFailure.socketConnection)
        await waitUntil {
            service.snapshot.sessionState == .failure
        }

        XCTAssertNotNil(service.snapshot.errorMessage)
        await service.dispose()
    }

    func testATaskErrorHandsTheConversationBackToTheOrb() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.error(wireType: "task_error"))
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertFalse(service.snapshot.microphoneActive)
        XCTAssertFalse(dependencies.recorder.isRecording)
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertTrue(
            service.protocolEvents.contains("task_error"),
        )
        await service.dispose()
    }

    func testACommandAfterDisposeIsIgnored() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()
        await service.dispose()

        await service.start()
        await service.stop()
        service.setMuted(true)

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(dependencies.recorder.startCalls, 1)
    }

    func testAStartAfterDisposeDoesNotStrandTheSharedLease() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.dispose()

        await service.start()

        XCTAssertNotNil(
            dependencies.sessionGuard.acquire(.transcription),
        )
    }

    func testConfiguredParametersReplaceTheCatalogDefaults() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService(
            parameterOverrides: [
                "transcription_model": "whisper-1",
                "turn_detection_threshold": "0.6",
                "voice": "cedar",
            ],
        )

        await service.start()

        XCTAssertEqual(
            stringParam(dependencies, "transcription_model"),
            "whisper-1",
        )
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?[
                "turn_detection_threshold",
            ] as? Double,
            0.6,
        )
        XCTAssertEqual(
            stringParam(dependencies, "voice"),
            ConversationConfig.voice,
        )
        await service.dispose()
    }

    func testKeepsTheLocalProtocolHistoryBounded() async {
        let dependencies = ConversationTestDependencies()
        let service = dependencies.createService()
        await service.start()

        for index in 0..<50 {
            dependencies.session.emit(
                .unknown(wireType: "future_event_\(index)"),
            )
        }

        XCTAssertEqual(service.protocolEvents.count, 40)
        await service.dispose()
    }
}

private func stringParam(
    _ dependencies: ConversationTestDependencies,
    _ key: String,
) -> String? {
    dependencies.apiClient.lastParameters?[key] as? String
}
