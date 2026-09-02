import AVFoundation
import Foundation
import os

/// Single `AVAudioEngine` graph for capture and playback.
///
/// Acoustic echo cancellation only works when the microphone tap and
/// the player share one engine. Features talk to this type through
/// `PcmCaptureSource` and `PcmPlaybackSink`; they never start the
/// engine themselves.
///
/// `RealtimeAudioSession.prepare` must have activated the shared
/// session before the graph starts. The graph does not deactivate
/// that session — teardown of category and activation stays there.
final class AVAudioEnginePcmGraph: @unchecked Sendable
{
    private struct State {
        var recording = false
        var disposed = false
        var captureContinuation:
            AsyncThrowingStream<Data, Error>.Continuation?
        var scheduledFrames: AVAudioFrameCount = 0
        var completedFrames: AVAudioFrameCount = 0
        var volume: Float = 1
        var fadeInPending = false
        var fadeTask: Task<Void, Never>?
    }

    /// A flush cuts the player mid-waveform, which the ear hears as a
    /// click; ramping the node down first turns the cut into a short
    /// fade. The answer that follows ramps back up over its first
    /// frames so it does not slam in after the silence. Both are kept
    /// well under a syllable so the interruption still feels instant.
    private static let fadeOutDuration: Duration = .milliseconds(80)
    private static let fadeInDuration: Duration = .milliseconds(40)
    private static let fadeStepDuration: Duration = .milliseconds(5)

    /// About 85 ms of input at the 48 kHz the hardware usually runs.
    /// The tap fires rarely enough that the resampling in
    /// `handleCapture` stays off the render thread's critical path;
    /// the recorder re-frames the result into 20 ms chunks anyway.
    private static let captureTapFrames: AVAudioFrameCount = 4_096

    /// Silence scheduled ahead of the first real buffer. Long enough
    /// to outlast the engine's start-up render gap, short enough not
    /// to read as latency on the first word.
    private static let primingSilenceSeconds = 0.1

    /// How often `endOfStream` re-checks the node's backlog. Finer
    /// than a chunk, so the tail is called done within a frame of the
    /// last sample playing out.
    private static let playoutPollInterval: Duration = .milliseconds(10)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let wireFormat: AVAudioFormat
    private let playbackQueue = DispatchQueue(
        label: "ai.wiro.audio.playback",
        qos: .userInteractive,
    )
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var playbackFormat: AVAudioFormat
    private var playbackConverter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?

    init() {
        // Int16 mono at the wire rate is a format Core Audio always
        // constructs; nil here would mean the constants are broken.
        wireFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConstants.sampleRateHz),
            channels: AVAudioChannelCount(AudioConstants.channelCount),
            interleaved: true,
        )!
        playbackFormat = wireFormat
        engine.attach(playerNode)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil,
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(
                configurationObserver,
            )
        }
    }

    var isRecording: Bool {
        state.withLock(\.recording)
    }

    func startCapture(
        _: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let busy = state.withLock { $0.disposed || $0.recording }
        if busy {
            throw AudioFailure.capture
        }
        guard restartEngineForCapture() else {
            throw AudioFailure.capture
        }
        guard installTap() else {
            throw AudioFailure.capture
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        state.withLock { state in
            state.recording = true
            state.captureContinuation = pair.continuation
        }
        return pair.stream
    }

    func stopRecording() {
        stopCapture()
    }

    func stopPlayback() async {
        cancelFade()
        playbackQueue.sync {
            resetPlayer()
        }
    }

    func initialize() async throws {
        if state.withLock(\.disposed) {
            throw AudioFailure.playback
        }
        guard ensureEngineRunning() else {
            throw AudioFailure.playback
        }
    }

    func play() async throws {
        playbackQueue.sync {
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    func feed(_ chunk: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            playbackQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AudioFailure.playback)
                    return
                }
                do {
                    try self.schedule(chunk)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: AudioFailure.playback)
                }
            }
        }
    }

    func flush() async throws {
        cancelFade()
        await fadeOut()
        playbackQueue.sync {
            resetPlayer()
            primePlayerNode()
        }
        state.withLock { $0.fadeInPending = true }
    }

    func bufferedDuration() async -> Duration {
        let pending = state.withLock { state in
            Int(state.scheduledFrames) - Int(state.completedFrames)
        }
        let rate = playbackFormat.sampleRate
        guard rate > 0, pending > 0 else {
            return .zero
        }
        return .seconds(Double(pending) / rate)
    }

    func setVolume(_ volume: Double) async throws {
        let clamped = Float(min(1, max(0, volume)))
        cancelFade()
        state.withLock { $0.volume = clamped }
        playerNode.volume = clamped
    }

    func endOfStream() async throws {
        while await bufferedDuration() > .zero {
            try await Task.sleep(for: Self.playoutPollInterval)
        }
    }

    func dispose() async {
        if state.withLock({ state in
            if state.disposed {
                return true
            }
            state.disposed = true
            return false
        }) {
            return
        }
        cancelFade()
        stopCapture()
        playbackQueue.sync {
            playerNode.stop()
            playerNode.reset()
        }
        engine.stop()
        finishCapture()
    }

    private func stopCapture() {
        let wasRecording = state.withLock { state -> Bool in
            guard state.recording else {
                return false
            }
            state.recording = false
            return true
        }
        guard wasRecording else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        finishCapture()
    }

    private func finishCapture(error: AudioFailure? = nil) {
        let continuation = state.withLock { state in
            let continuation = state.captureContinuation
            state.captureContinuation = nil
            return continuation
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func restartEngineForCapture() -> Bool {
        playbackQueue.sync {
            playerNode.stop()
            playerNode.reset()
        }
        engine.stop()
        engine.reset()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
        connectGraph()
        toggleVoiceProcessing()
        do {
            try engine.start()
            primePlayerNode()
            return true
        } catch {
            return false
        }
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning {
            return true
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            connectGraph()
            try engine.start()
            primePlayerNode()
            return true
        } catch {
            return false
        }
    }

    private func connectGraph() {
        refreshPlaybackFormat()
        engine.connect(
            playerNode,
            to: engine.mainMixerNode,
            format: playbackFormat,
        )
        engine.connect(
            engine.mainMixerNode,
            to: engine.outputNode,
            format: nil,
        )
        engine.mainMixerNode.outputVolume = 1
        playerNode.volume = state.withLock(\.volume)
    }

    private func refreshPlaybackFormat() {
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        if mixer.sampleRate > 0, mixer.channelCount > 0 {
            playbackFormat = mixer
        }
        playbackConverter = AVAudioConverter(
            from: wireFormat,
            to: playbackFormat,
        )
    }

    private func toggleVoiceProcessing() {
        let input = engine.inputNode
        do {
            if input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(false)
            }
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Simulator and some routes refuse the toggle; capture
            // is still worth starting without AEC.
        }
        // AGC deliberately stays on: without it the assistant's own
        // echo residual — never fully removed by cancellation alone
        // — swings unevenly past `ConversationVoiceActivity`'s
        // interrupt threshold in bursts, which reads as the user
        // interrupting the assistant's own voice. That repeatedly
        // holds and flushes playback and then dumps the backlog at
        // once, which is worse than the near-silent capture AGC
        // otherwise leaves during a real interruption.
    }

    private func installTap() -> Bool {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            return false
        }
        guard let converter = AVAudioConverter(
            from: native,
            to: wireFormat,
        ) else {
            return false
        }
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: Self.captureTapFrames,
            format: nil,
        ) { [weak self, converter] buffer, _ in
            self?.handleCapture(buffer, converter: converter)
        }
        return true
    }

    private func handleCapture(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
    ) {
        let ratio = converter.outputFormat.sampleRate
            / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(),
        )
        guard capacity > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: capacity,
              )
        else {
            return
        }
        var error: NSError?
        let source = SingleBufferInput(buffer)
        let status = converter.convert(to: output, error: &error) {
            _, outStatus in
            source.next(outStatus)
        }
        if error != nil || status == .error {
            return
        }
        guard let channels = output.int16ChannelData else {
            return
        }
        let byteCount = Int(output.frameLength)
            * MemoryLayout<Int16>.size
            * Int(output.format.channelCount)
        guard byteCount > 0 else {
            return
        }
        let data = Data(bytes: channels[0], count: byteCount)
        state.withLock(\.captureContinuation)?.yield(data)
    }

    private func schedule(_ audioData: Data) throws {
        guard ensureEngineRunning(),
              let converter = playbackConverter
        else {
            throw AudioFailure.playback
        }
        let frameCount = AVAudioFrameCount(
            audioData.count
                / (MemoryLayout<Int16>.size
                    * Int(wireFormat.channelCount)),
        )
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(
                  pcmFormat: wireFormat,
                  frameCapacity: frameCount,
              )
        else {
            throw AudioFailure.playback
        }
        input.frameLength = frameCount
        audioData.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress
            else {
                return
            }
            input.int16ChannelData?[0].update(
                from: source,
                count: Int(frameCount * wireFormat.channelCount),
            )
        }
        let outputCapacity = AVAudioFrameCount(
            (Double(frameCount) * playbackFormat.sampleRate
                / wireFormat.sampleRate).rounded(),
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity,
        ) else {
            throw AudioFailure.playback
        }
        var error: NSError?
        let source = SingleBufferInput(input)
        let status = converter.convert(to: output, error: &error) {
            _, outStatus in
            source.next(outStatus)
        }
        if error != nil || status == .error {
            throw AudioFailure.playback
        }
        guard output.frameLength > 0 else {
            return
        }
        let frames = output.frameLength
        let fadeIn = state.withLock { state -> Bool in
            state.scheduledFrames += frames
            let pending = state.fadeInPending
            state.fadeInPending = false
            return pending
        }
        playerNode.scheduleBuffer(output) { [weak self] in
            self?.state.withLock { $0.completedFrames += frames }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        if fadeIn {
            startFadeIn()
        }
    }

    private func resetPlayer() {
        playerNode.stop()
        playerNode.reset()
        state.withLock { state in
            state.scheduledFrames = 0
            state.completedFrames = 0
        }
    }

    /// Ramps the node down from wherever it is — a fade-in may still
    /// be under way — over what is still buffered; skipped when nothing
    /// is buffered so an idle flush costs no time.
    private func fadeOut() async {
        let from = playerNode.volume
        guard from > 0, playerNode.isPlaying,
              await bufferedDuration() > .zero
        else {
            return
        }
        let steps = Int(Self.fadeOutDuration / Self.fadeStepDuration)
        for step in stride(from: steps - 1, through: 0, by: -1) {
            playerNode.volume = from * Float(step) / Float(steps)
            try? await Task.sleep(for: Self.fadeStepDuration)
        }
    }

    /// Ramps from wherever the node was left — zero after a fade-out,
    /// or the full level if `setVolume` ran in between — up to the
    /// configured volume, so the ramp never dips what is playing.
    private func startFadeIn() {
        let target = state.withLock(\.volume)
        let from = playerNode.volume
        guard from < target else {
            return
        }
        let steps = Int(Self.fadeInDuration / Self.fadeStepDuration)
        let task = Task { [weak self] in
            for step in 1...steps {
                guard let self, !Task.isCancelled else {
                    return
                }
                playerNode.volume =
                    from + (target - from) * Float(step) / Float(steps)
                try? await Task.sleep(for: Self.fadeStepDuration)
            }
        }
        state.withLock { state in
            state.fadeTask?.cancel()
            state.fadeTask = task
        }
    }

    private func cancelFade() {
        state.withLock { state in
            state.fadeTask?.cancel()
            state.fadeTask = nil
        }
    }

    /// A cold first `play()` racing engine start can render the first
    /// real buffer twice. Priming establishes the render timeline on
    /// silence so the first chunk appends to a running node.
    private func primePlayerNode() {
        let frameCount = AVAudioFrameCount(
            playbackFormat.sampleRate * Self.primingSilenceSeconds,
        )
        guard frameCount > 0,
              let silence = AVAudioPCMBuffer(
                  pcmFormat: playbackFormat,
                  frameCapacity: frameCount,
              )
        else {
            return
        }
        silence.frameLength = frameCount
        playerNode.scheduleBuffer(silence, completionHandler: nil)
        playerNode.play()
    }

    private func handleConfigurationChange() {
        // Only a live capture is worth reviving. Restarting an idle
        // engine here would re-activate a session the session owner
        // already let go of, and leave a zombie for the next turn.
        guard state.withLock(\.recording), !engine.isRunning else {
            return
        }
        if ensureEngineRunning() {
            _ = installTap()
        }
    }
}

// The graph cannot adopt `PcmCaptureSource` and `PcmPlaybackSink`
// itself: both require `stop()`, one meaning the microphone and the
// other the speaker, so each side gets a thin adapter.
private final class EnginePcmCaptureSource:
    PcmCaptureSource, @unchecked Sendable
{
    private let graph: AVAudioEnginePcmGraph

    init(_ graph: AVAudioEnginePcmGraph) {
        self.graph = graph
    }

    var isRecording: Bool {
        graph.isRecording
    }

    func start(
        _ profile: PcmCaptureProfile,
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await graph.startCapture(profile)
    }

    func stop() async {
        graph.stopRecording()
    }

    func dispose() async {
        await graph.dispose()
    }
}

private final class EnginePcmPlaybackSink:
    PcmPlaybackSink, @unchecked Sendable
{
    private let graph: AVAudioEnginePcmGraph

    init(_ graph: AVAudioEnginePcmGraph) {
        self.graph = graph
    }

    func initialize() async throws {
        try await graph.initialize()
    }

    func play() async throws {
        try await graph.play()
    }

    func feed(_ chunk: Data) async throws {
        try await graph.feed(chunk)
    }

    func flush() async throws {
        try await graph.flush()
    }

    func bufferedDuration() async -> Duration {
        await graph.bufferedDuration()
    }

    func setVolume(_ volume: Double) async throws {
        try await graph.setVolume(volume)
    }

    func endOfStream() async throws {
        try await graph.endOfStream()
    }

    func stop() async throws {
        await graph.stopPlayback()
    }

    func dispose() async {
        await graph.dispose()
    }
}

/// Conversation adapters sharing one native input/output graph.
final class AVAudioEnginePcmAudio: @unchecked Sendable {
    let recorder: BufferedPcmAudioRecorder
    let player: QueuedPcmAudioPlayer

    init(
        playerQueueCapacityInChunks: Int =
            AudioConstants.defaultQueueCapacityInChunks,
    ) {
        let graph = AVAudioEnginePcmGraph()
        recorder = BufferedPcmAudioRecorder(
            EnginePcmCaptureSource(graph),
        )
        player = QueuedPcmAudioPlayer(
            EnginePcmPlaybackSink(graph),
            queueCapacityInChunks: playerQueueCapacityInChunks,
        )
    }

    func dispose() async {
        await player.dispose()
        await recorder.dispose()
    }
}

/// Feeds exactly one buffer to `AVAudioConverter.convert`.
///
/// The converter calls its input block synchronously on the calling
/// thread, but newer SDKs type the block `@Sendable`, so the one-shot
/// flag lives in a box rather than in a captured local.
private final class SingleBufferInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var provided = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        _ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>,
    ) -> AVAudioPCMBuffer? {
        if provided {
            outStatus.pointee = .noDataNow
            return nil
        }
        provided = true
        outStatus.pointee = .haveData
        return buffer
    }
}
