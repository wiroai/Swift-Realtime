import Foundation

/// Commands a text-to-speech session and reports it as snapshots.
///
/// The view model depends on this contract rather than on
/// `TextToSpeechSessionService` so it can be exercised without audio
/// hardware or a network stack.
///
/// Every command is a no-op once `dispose` has run.
protocol SpeechSessionController: AnyObject, Sendable {
    var snapshots: AsyncStream<SpeechSessionSnapshot> { get }
    var snapshot: SpeechSessionSnapshot { get }
    var parameters: ModelParameterValues { get }
    var sessionGuard: RealtimeSessionGuard { get }
    var prompt: String { get set }

    func selectModel(_ model: ModelDefinition)
    func setParameter(_ value: String, for id: String)
    func start() async
    func stop() async
    func dispose() async
}
