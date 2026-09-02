import Foundation

/// Keeps steady background sound — a television, traffic, a fan — out
/// of the microphone stream while letting near-field speech through.
///
/// Closed chunks are strongly attenuated instead of dropped or zeroed,
/// so the uplink keeps real-time pacing and carries room tone: the
/// server's voice detection hears a quiet room rather than a dead wire.
final class PcmNoiseGate {
    /// The gate never opens below this level, which separates
    /// near-field speech from a room at conversational television
    /// volume.
    let minOpenLevel: Double

    /// Opening bar while assistant audio is audible. Speaker bleed
    /// that echo cancellation misses must not reach the server.
    ///
    /// This bar is the real switch for whether an interruption ever
    /// works: the model's own turn-taking has no cancel message on
    /// this task's realtime protocol, so the uploaded microphone
    /// audio is the only way the server ever learns someone is
    /// talking over it. Set this any higher than a hair above what
    /// echo cancellation leaves behind and a normal, un-shouted
    /// interruption gets attenuated away before the server — or this
    /// app's own barge-in, which reads the same gated level — ever
    /// sees it, and the assistant talks straight through it.
    let assistantOpenLevel: Double

    /// How far above the learned ambient floor a chunk must rise to
    /// count as the user rather than the room.
    let floorMultiplier: Double

    /// Ceiling for the learned floor, so a loud room cannot push the
    /// opening threshold beyond what a raised voice reaches.
    let floorCap: Double

    /// How long the gate stays open after the last loud chunk, so the
    /// dip between two words does not chop the sentence apart.
    let hangover: Duration

    /// Share of the opening threshold a chunk must still reach to
    /// ride the hangover through.
    let hangoverFraction: Double

    /// Gain applied to closed chunks. Pure digital zeros can read as
    /// a dead stream and get the task reaped after long quiet spells.
    let closedGain: Double

    /// How little the signal has to move, relative to its own
    /// loudness, to be called a machine rather than a voice.
    let flatnessLimit: Double

    /// Chunks of loudness history the flatness test reads. At fifty
    /// chunks a second this is one second.
    private static let historyLength = 50

    /// Loud sound that persists for tens of seconds is a room, not a
    /// sentence. This creep absorbs a loud television in well under a
    /// minute while a long utterance barely moves the floor.
    private static let loudCaptureAlpha = 0.001

    /// Creep rate for sound the flatness test has identified as a
    /// machine, fast enough to close on a hum a second or so after
    /// recognising it.
    private static let steadyCaptureAlpha = 0.02

    /// Creep rates for quiet chunks. Rising slowly and falling
    /// quickly means a brief racket cannot lock the gate shut for
    /// long after the room calms down.
    private static let quietRiseAlpha = 0.04
    private static let quietFallAlpha = 0.12

    private var history: [Double]
    private var historyCount = 0
    private var historyCursor = 0
    private var floor = 0.0
    private var lastOutputLevelValue = 0.0
    private var openUntil: ContinuousClock.Instant?

    /// Ambient loudness the gate currently attributes to the room.
    var ambientFloor: Double { floor }

    /// Loudness of the most recent `process` output, on the same
    /// scale as `pcmNormalizedLevel`.
    var lastOutputLevel: Double { lastOutputLevelValue }

    /// True while the recent signal has been too flat to be a voice.
    ///
    /// Undecided until a full window has been heard: one chunk of
    /// anything looks flat, and calling a hum on that would shut the
    /// gate on the first syllable of every sentence.
    var hearsHum: Bool {
        guard historyCount >= Self.historyLength else {
            return false
        }
        let mean = history.reduce(0, +) / Double(Self.historyLength)
        guard mean > 0 else {
            return false
        }
        var squares = 0.0
        for level in history {
            let deviation = level - mean
            squares += deviation * deviation
        }
        let spread = (squares / Double(Self.historyLength)).squareRoot()
        return spread / mean < flatnessLimit
    }

    var isOpen: Bool {
        guard let openUntil else {
            return false
        }
        return ContinuousClock.now < openUntil
    }

    init(
        minOpenLevel: Double = 0.28,
        assistantOpenLevel: Double = 0.32,
        floorMultiplier: Double = 1.6,
        floorCap: Double = 0.5,
        hangover: Duration = .milliseconds(600),
        hangoverFraction: Double = 0.5,
        flatnessLimit: Double = 0.15,
        closedGain: Double = 0.05,
    ) {
        self.minOpenLevel = minOpenLevel
        self.assistantOpenLevel = assistantOpenLevel
        self.floorMultiplier = floorMultiplier
        self.floorCap = floorCap
        self.hangover = hangover
        self.hangoverFraction = hangoverFraction
        self.flatnessLimit = flatnessLimit
        self.closedGain = closedGain
        history = Array(repeating: 0, count: Self.historyLength)
    }

    /// Returns the chunk untouched while the gate is open, or the
    /// same chunk attenuated to a whisper while it is closed.
    ///
    /// `assistantAudible` raises the opening bar to
    /// `assistantOpenLevel` while the assistant is playing through
    /// the speaker, so echo leaking past cancellation cannot open
    /// the gate.
    func process(
        _ chunk: Data,
        assistantAudible: Bool = false,
    ) -> Data {
        let level = pcmNormalizedLevel(chunk)
        history[historyCursor] = level
        historyCursor = (historyCursor + 1) % Self.historyLength
        if historyCount < Self.historyLength {
            historyCount += 1
        }
        let now = ContinuousClock.now
        let baseOpenLevel = assistantAudible
            ? max(minOpenLevel, assistantOpenLevel)
            : minOpenLevel
        let openThreshold = max(baseOpenLevel, floor * floorMultiplier)
        if level >= openThreshold {
            openUntil = now + hangover
            raiseFloor(
                level,
                alpha: hearsHum
                    ? Self.steadyCaptureAlpha
                    : Self.loudCaptureAlpha,
            )
            lastOutputLevelValue = level
            return chunk
        }
        // Quiet chunks teach the floor.
        raiseFloor(
            level,
            alpha: level > floor
                ? Self.quietRiseAlpha
                : Self.quietFallAlpha,
        )
        if let openUntil, now < openUntil,
           level >= openThreshold * hangoverFraction
        {
            lastOutputLevelValue = level
            return chunk
        }
        lastOutputLevelValue = level * closedGain
        return attenuated(chunk)
    }

    /// Forgets the learned room so a new session starts fresh.
    func reset() {
        floor = 0
        lastOutputLevelValue = 0
        history = Array(repeating: 0, count: Self.historyLength)
        historyCount = 0
        historyCursor = 0
        openUntil = nil
    }

    private func raiseFloor(_ level: Double, alpha: Double) {
        floor = min(floorCap, floor + (level - floor) * alpha)
    }

    private func attenuated(_ chunk: Data) -> Data {
        var copy = Data(chunk)
        copy.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<samples.count {
                let scaled = Double(samples[index]) * closedGain
                samples[index] = Int16(scaled.rounded())
            }
        }
        return copy
    }
}
