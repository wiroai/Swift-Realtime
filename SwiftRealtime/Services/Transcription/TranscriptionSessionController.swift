import Foundation

/// Commands a transcription session and reports it as snapshots.
///
/// The view model depends on this contract rather than on
/// `SpeechToTextSessionService` so it can be exercised without audio
/// hardware or a network stack.
///
/// Every command is a no-op once `dispose` has run.
protocol TranscriptionSessionController: AnyObject, Sendable {
    var snapshots: AsyncStream<TranscriptionSessionSnapshot> { get }
    var snapshot: TranscriptionSessionSnapshot { get }
    var model: ModelDefinition { get }
    var parameters: ModelParameterValues { get }
    var sessionGuard: RealtimeSessionGuard { get }

    func start() async
    func stop() async
    func setMuted(_ muted: Bool)
    func setParameter(_ value: String, for id: String)
    func clearTranscript()
    func openSystemSettings() async
    func dispose() async
}
