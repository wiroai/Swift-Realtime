import XCTest
@testable import SwiftRealtime

final class SpeechToTextSessionServiceTests: XCTestCase {
    func testRunsVoxtralAndStreamsPrefixedPCMAfterReadiness() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()

        await service.start()
        dependencies.recorder.emit(Data([1, 2, 3]))
        await waitUntil {
            dependencies.session.sentAudio.count == 1
        }

        XCTAssertEqual(
            dependencies.audioSession.preparedProfiles,
            [.transcription],
        )
        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(
            dependencies.apiClient.lastParameters?[
                "transcriptionDelay",
            ] as? String,
            "balanced",
        )
        XCTAssertEqual(
            dependencies.session.sentAudio,
            [Data([1, 2, 3])],
        )
        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertTrue(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testAGrowingUtteranceRefinesTheTranscriptInPlace() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.output("TRANSCRIPT_USER:Hello"))
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Hello world"),
        )

        XCTAssertEqual(service.snapshot.transcript, "Hello world")
        XCTAssertEqual(
            service.protocolEvents.filter {
                $0 == "task_output"
            }.count,
            2,
        )
        await service.dispose()
    }

    func testANewUtteranceJoinsTheTranscriptInsteadOfErasingIt()
        async
    {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Hello world."),
        )
        dependencies.session.emit(.output("TRANSCRIPT_USER:How are"))
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:How are you?"),
        )
        dependencies.session.emit(.output("TRANSCRIPT_USER:Good."))

        XCTAssertEqual(
            service.snapshot.transcript,
            "Hello world. How are you? Good.",
        )
        await service.dispose()
    }

    func testAShorterReEmitOfTheLiveUtteranceChangesNothing() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Hello world"),
        )
        dependencies.session.emit(.output("TRANSCRIPT_USER:Hello"))

        XCTAssertEqual(service.snapshot.transcript, "Hello world")
        await service.dispose()
    }

    func testANewTakeStartsFromABlankTranscript() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Old take"),
        )
        await service.stop()

        await service.start()
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:New take"),
        )

        XCTAssertEqual(service.snapshot.transcript, "New take")
        await service.dispose()
    }

    func testStopReleasesMicrophoneAndSendsOneSessionEnd() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        async let firstStop: Void = service.stop()
        async let secondStop: Void = service.stop()
        _ = await (firstStop, secondStop)

        XCTAssertEqual(dependencies.recorder.stopCalls, 1)
        XCTAssertEqual(dependencies.audioSession.deactivateCalls, 1)
        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        XCTAssertEqual(dependencies.session.closeCalls, 1)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        XCTAssertFalse(service.snapshot.microphoneActive)
        await service.dispose()
    }

    func testASlowShutdownConfirmationCompletesWithoutAnError()
        async
    {
        let dependencies = TranscriptionTestDependencies(
            completeSessionEnd: false,
        )
        let service = dependencies.createService()
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

    func testMapsDeniedMicrophonePermissionWithoutRunningATask()
        async
    {
        let dependencies = TranscriptionTestDependencies(
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
        let dependencies = TranscriptionTestDependencies(
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

    func testCancelsAPendingRunRequestDuringStop() async {
        let dependencies = TranscriptionTestDependencies()
        dependencies.apiClient.holdRunModel = true
        let service = dependencies.createService()
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
            dependencies.apiClient.lastCancellation?.isCancelled,
            true,
        )
        XCTAssertEqual(dependencies.session.connectCalls, 0)
        XCTAssertEqual(service.snapshot.sessionState, .completed)
        await service.dispose()
    }

    func testTerminatesARunResultThatArrivesAfterStop() async {
        let dependencies = TranscriptionTestDependencies()
        dependencies.apiClient.holdRunModel = true
        let service = dependencies.createService()
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

    func testStreamEndStopsCaptureBeforeNaturalCompletion() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.status(.streamEnded))
        await waitUntil {
            service.snapshot.sessionState == .stopping
        }

        XCTAssertFalse(service.snapshot.microphoneActive)
        XCTAssertEqual(dependencies.recorder.stopCalls, 1)
        XCTAssertEqual(dependencies.session.closeCalls, 0)
        await service.dispose()
    }

    func testCompletesNaturallyAfterPostprocessEnd() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.status(.streamEnded))
        dependencies.session.emit(.status(.postprocessEnded))
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertFalse(service.snapshot.microphoneActive)
        XCTAssertEqual(dependencies.recorder.stopCalls, 1)
        await service.dispose()
    }

    func testRejectsUnexpectedServerAudioForSTT() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.session.emit(.binary(Data([1, 2])))
        await waitUntil {
            service.snapshot.sessionState == .failure
        }

        XCTAssertEqual(service.snapshot.sessionState, .failure)
        XCTAssertFalse(
            service.snapshot.errorMessage?.contains("1, 2") ?? true,
        )
        XCTAssertTrue(
            service.protocolEvents
                .contains("failure:realtimeProtocol"),
        )
        await service.dispose()
    }

    func testClearTranscriptIsInactiveOnlyBusinessBehavior() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()
        dependencies.session.emit(
            .output("TRANSCRIPT_USER:Keep me"),
        )

        service.clearTranscript()
        XCTAssertEqual(service.snapshot.transcript, "Keep me")

        await service.stop()
        service.clearTranscript()
        XCTAssertTrue(service.snapshot.transcript.isEmpty)
        await service.dispose()
    }

    func testMuteDropsMicrophoneAudioWithoutClosingTheSession()
        async
    {
        let dependencies = TranscriptionTestDependencies()
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

    func testStopsAnActiveSessionWhenAudioIsInterrupted() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()

        dependencies.audioSession.emitInterruption(.began)
        await waitUntil {
            service.snapshot.sessionState == .completed
        }

        XCTAssertEqual(dependencies.session.sessionEndCalls, 1)
        await service.dispose()
    }

    func testCommandsAfterDisposeAreSafeNoOps() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.start()
        await service.dispose()
        let snapshot = service.snapshot

        await service.start()
        await service.stop()
        service.clearTranscript()

        XCTAssertEqual(dependencies.apiClient.runCalls, 1)
        XCTAssertEqual(dependencies.recorder.startCalls, 1)
        XCTAssertEqual(service.snapshot, snapshot)
    }

    func testAStartAfterDisposeDoesNotStrandTheSharedLease() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        await service.dispose()

        await service.start()

        XCTAssertNotNil(
            dependencies.sessionGuard.acquire(.conversation),
        )
    }

    func testAStartDuringAnotherFeatureTeardownWaitsItOut() async {
        let dependencies = TranscriptionTestDependencies()
        let service = dependencies.createService()
        let departing = dependencies.sessionGuard.acquire(
            .conversation,
        )

        let starting = Task { await service.start() }
        await waitUntil {
            service.snapshot.sessionState == .requestingPermission
        }
        dependencies.sessionGuard.release(departing)
        await starting.value

        XCTAssertEqual(service.snapshot.sessionState, .streaming)
        XCTAssertNil(service.snapshot.errorMessage)
        await service.dispose()
    }

    func testKeepsTheLocalProtocolHistoryBounded() async {
        let dependencies = TranscriptionTestDependencies()
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
