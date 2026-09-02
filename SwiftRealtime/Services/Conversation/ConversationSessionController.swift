import Foundation

/// Commands a two-way speech conversation and reports it as snapshots.
///
/// The view model depends on this contract rather than on
/// `SpeechToSpeechSessionService` so it can be exercised without audio
/// hardware or a network stack.
///
/// Every command is a no-op once `dispose` has run.
protocol ConversationSessionController: AnyObject, Sendable {
    var snapshots: AsyncStream<ConversationSessionSnapshot> { get }
    var snapshot: ConversationSessionSnapshot { get }
    var model: ModelDefinition { get }
    var parameters: ModelParameterValues { get }
    var sessionGuard: RealtimeSessionGuard { get }

    func start() async
    func stop() async
    func changeVoice(_ voice: String) async
    func suspend() async
    func resume() async
    func setMuted(_ muted: Bool)
    func setParameter(_ value: String, for id: String)
    func interruptAssistant()
    /// The screen was touched. Barge-in detection ignores the burst
    /// the finger makes in the microphone.
    func noteScreenTouch()
    func openSystemSettings() async
    func dispose() async
}
