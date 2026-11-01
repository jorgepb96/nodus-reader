// SPDX-License-Identifier: AGPL-3.0-only
import AudioToolbox
import AVFoundation
import Foundation

/// Plays Immersive Audio: two music decks and two ambience decks on an
/// engine of their own, beside narration's.
///
/// Narration keeps its own engine (`PlaybackController`), which pauses on
/// every skip, seek and speed change. A separate engine means music never
/// cuts out when narration moves, and nothing here can restart a sentence.
/// Both engines share the app's audio session (`AudioSessionCoordinator`).
///
/// ```
/// music deck A/B (player → fade) ─→ music bus ───┐
/// ambience deck A/B (player → fade) → ambience bus ┴→ master → limiter → ceiling → main mixer
/// ```
/// Everything after the decks is 48 kHz stereo, so music keeps its stereo
/// image; a deck is wired in its file's own format (the mixers convert).
///
/// Gains follow pure curves (`GainCurve`) evaluated at this engine's clock
/// by a timer on its queue; tests render offline and drive the same
/// automation from the rendered sample time.
final class ImmersiveAudioEngine: @unchecked Sendable {
    enum Layer: String, Sendable, CaseIterable {
        case music
        case ambience
    }

    enum RenderMode: Sendable {
        case realtime
        /// Manual rendering for tests: `render(seconds:)` pulls audio.
        case offline(sampleRate: Double)
    }

    enum EngineError: Error {
        case cannotStart
        case unreadableFile
    }

    struct TrackRequest: Sendable {
        var id: String
        var url: URL
        var layer: Layer
        var loop: Bool
        /// Seconds into the piece where the next one may begin (music).
        var tailStart: TimeInterval?
        /// Level correction for this file (1 = as mastered).
        var gain: Double = 1
    }

    /// Called on the main queue (realtime) or inline (offline).
    var onTrackTail: (@Sendable (Layer, String) -> Void)?
    var onTrackEnded: (@Sendable (Layer, String) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    // MARK: Graph

    private final class Deck {
        let player = AVAudioPlayerNode()
        let fade = AVAudioMixerNode()
        var format: AVAudioFormat?
        var file: AVAudioFile?
        var trackID: String?
        var loop = false
        var tailStart: TimeInterval?
        var tailNotified = false
        var ramp = GainRamp.hold(0)
        var generation = 0
        /// File frame where the current schedule began.
        var startFrame: AVAudioFramePosition = 0
        /// Last known position, kept for a restart after a configuration change.
        var savedFrame: AVAudioFramePosition = 0
        var trackGain = 1.0

        var isActive: Bool { file != nil }
    }

    private let mode: RenderMode
    private let silent: Bool
    private let queue = DispatchQueue(label: "ai.nodus.reader.immersive-audio", qos: .userInitiated)
    private static let internalRate = 48_000.0

    private var engine: AVAudioEngine?
    private var decks: [Layer: [Deck]] = [:]
    private var buses: [Layer: AVAudioMixerNode] = [:]
    private var master = AVAudioMixerNode()
    private var limiter: AVAudioUnitEffect?
    private var trim = AVAudioMixerNode()
    private var configurationObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?

    // MARK: Automation state

    private var userGain: [Layer: GainRamp] = [.music: .hold(VolumeTaper.gain(0.5)), .ambience: .hold(VolumeTaper.gain(0.5))]
    private var musicDuck = DuckingEnvelope(depth: -10)
    private var ambienceDuck = DuckingEnvelope(depth: -4)
    private var silenceRamp = GainRamp.hold(1)
    private var masterRamp = GainRamp.hold(0)
    private var ceilingRamp = GainRamp.hold(0.89)
    private var appliedPreGain: Float = .nan
    private var pauseAfterFade = false
    private(set) var isRunning = false
    private(set) var isPaused = false

    // Clock: realtime seconds without the time spent paused; offline, the
    // rendered sample time.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: TimeInterval?
    private var renderedFrames: AVAudioFramePosition = 0
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval = 0

    init(mode: RenderMode = .realtime, silent: Bool = false) {
        self.mode = mode
        self.silent = silent
        queue.sync { buildGraph() }
    }

    deinit {
        timer?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    private var isOffline: Bool {
        if case .offline = mode { return true }
        return false
    }

    /// Runs on the engine queue: synchronously offline (deterministic tests),
    /// asynchronously in realtime (callers never wait on audio).
    private func perform(_ work: @escaping () -> Void) {
        if isOffline { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    private func buildGraph() {
        let engine = AVAudioEngine()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: Self.internalRate, channels: 2)!
        if case .offline(let rate) = mode {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        master = AVAudioMixerNode()
        trim = AVAudioMixerNode()
        engine.attach(master)
        engine.attach(trim)
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                    componentSubType: kAudioUnitSubType_PeakLimiter,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        let limiter = AVAudioUnitEffect(audioComponentDescription: description)
        engine.attach(limiter)
        self.limiter = limiter
        for layer in Layer.allCases {
            let bus = AVAudioMixerNode()
            engine.attach(bus)
            engine.connect(bus, to: master, format: stereo)
            buses[layer] = bus
            var pair: [Deck] = []
            for _ in 0..<2 {
                let deck = Deck()
                engine.attach(deck.player)
                engine.attach(deck.fade)
                engine.connect(deck.player, to: deck.fade, format: stereo)
                engine.connect(deck.fade, to: bus, format: stereo)
                deck.format = stereo
                deck.fade.outputVolume = 0
                pair.append(deck)
            }
            decks[layer] = pair
        }
        engine.connect(master, to: limiter, format: stereo)
        engine.connect(limiter, to: trim, format: stereo)
        engine.connect(trim, to: engine.mainMixerNode, format: stereo)
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_AttackTime),
                              kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_DecayTime),
                              kAudioUnitScope_Global, 0, 0.08, 0)
        master.outputVolume = 0
        engine.prepare()
        self.engine = engine
        appliedPreGain = .nan
        observe(engine)
    }

    private func observe(_ engine: AVAudioEngine) {
        guard !isOffline else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }
        #if os(iOS)
        if resetObserver == nil {
            resetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.rebuildAfterReset() }
            }
        }
        #endif
    }

    // MARK: Clock and automation

    private func now() -> TimeInterval {
        switch mode {
        case .offline(let rate):
            return Double(renderedFrames) / rate
        case .realtime:
            let uptime = ProcessInfo.processInfo.systemUptime
            return (pausedAt ?? uptime) - pausedTotal
        }
    }

    private var isMoving: Bool {
        let t = now()
        if !masterRamp.isFinished(at: t) || !silenceRamp.isFinished(at: t) || !ceilingRamp.isFinished(at: t) { return true }
        if musicDuck.isMoving(at: t) || ambienceDuck.isMoving(at: t) { return true }
        if userGain.values.contains(where: { !$0.isFinished(at: t) }) { return true }
        return decks.values.joined().contains { $0.isActive && !$0.ramp.isFinished(at: t) }
    }

    /// Applies every gain at the current clock, retires faded-out decks,
    /// reports tails and remembers positions. Runs on the queue.
    private func tick() {
        let t = now()
        for layer in Layer.allCases {
            for deck in decks[layer] ?? [] where deck.isActive {
                deck.fade.outputVolume = Float(deck.ramp.value(at: t))
                if deck.ramp.isFinished(at: t), deck.ramp.to <= 0 {
                    stopDeck(deck)
                    continue
                }
                savePosition(deck)
                if !deck.tailNotified, let tail = deck.tailStart, let id = deck.trackID,
                   Double(deck.savedFrame) / (deck.file?.processingFormat.sampleRate ?? 1) >= tail {
                    deck.tailNotified = true
                    notify { [onTrackTail] in onTrackTail?(layer, id) }
                }
            }
        }
        let music = userGain[.music]!.value(at: t) * Headroom.musicBusCap * musicDuck.gain(at: t) * silenceRamp.value(at: t)
        let ambience = userGain[.ambience]!.value(at: t) * Headroom.ambienceBusCap * ambienceDuck.gain(at: t)
        buses[.music]?.outputVolume = Float(music)
        buses[.ambience]?.outputVolume = Float(ambience)
        master.outputVolume = silent ? 0 : Float(masterRamp.value(at: t))
        let ceiling = Float(ceilingRamp.value(at: t))
        trim.outputVolume = ceiling
        // The limiter sees the mix raised by 1/ceiling, limits it at full scale,
        // and the trim brings it back: peaks end at the ceiling, nothing else moves.
        let preGain = -20 * log10(max(ceiling, 0.05))
        if let limiter, abs(preGain - appliedPreGain) > 0.01 || appliedPreGain.isNaN {
            AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_PreGain),
                                  kAudioUnitScope_Global, 0, preGain, 0)
            appliedPreGain = preGain
        }
        if pauseAfterFade, masterRamp.isFinished(at: t) {
            pauseAfterFade = false
            pauseEngineNow()
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        guard !isOffline else { return }
        let active = isRunning && !isPaused
        guard active else {
            timer?.cancel()
            timer = nil
            return
        }
        let interval = isMoving ? 0.01 : 0.25
        if timer != nil, interval == timerInterval { return }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
        timerInterval = interval
    }

    /// Offline callbacks wait until the render block has left the queue, so
    /// they may call back into the engine.
    private var pendingCallbacks: [@Sendable () -> Void] = []

    private func notify(_ body: @escaping @Sendable () -> Void) {
        if isOffline { pendingCallbacks.append(body) } else { DispatchQueue.main.async(execute: body) }
    }

    private func flushCallbacks() {
        let callbacks = queue.sync { () -> [@Sendable () -> Void] in
            defer { pendingCallbacks = [] }
            return pendingCallbacks
        }
        callbacks.forEach { $0() }
    }

    // MARK: Engine lifecycle

    /// Starts the engine (after the audio session was claimed).
    func start(fadeIn: TimeInterval = 1.2) {
        perform { [self] in
            guard let engine else { return }
            if isPaused, let at = pausedAt {
                pausedTotal += ProcessInfo.processInfo.systemUptime - at
                pausedAt = nil
                isPaused = false
            }
            if !isOffline, !engine.isRunning {
                do { try engine.start() } catch {
                    isRunning = false
                    notify { [onFailure] in onFailure?(error) }
                    return
                }
            } else if isOffline, !engine.isRunning {
                try? engine.start()
            }
            isRunning = true
            for deck in decks.values.joined() where deck.isActive && !deck.player.isPlaying {
                deck.player.play()
            }
            pauseAfterFade = false
            let t = now()
            masterRamp = GainRamp(from: masterRamp.value(at: t), to: 1, start: t, duration: fadeIn, shape: .equalPower)
            tick()
        }
    }

    /// Fades out, then pauses the engine (players keep their place).
    func pause(fadeOut: TimeInterval) {
        perform { [self] in
            guard isRunning, !isPaused else { return }
            let t = now()
            masterRamp = GainRamp(from: masterRamp.value(at: t), to: 0, start: t, duration: fadeOut, shape: .equalPower)
            pauseAfterFade = true
            if fadeOut <= 0 { tick() } else { scheduleTimer() }
        }
    }

    private func pauseEngineNow() {
        guard let engine, !isOffline else { return }
        for deck in decks.values.joined() where deck.isActive { savePosition(deck) }
        engine.pause()
        isPaused = true
        pausedAt = ProcessInfo.processInfo.systemUptime
        timer?.cancel()
        timer = nil
    }

    /// Stops everything and releases the engine, nodes and files.
    func shutdown() {
        let work = { [self] in
            timer?.cancel()
            timer = nil
            for deck in decks.values.joined() { stopDeck(deck) }
            engine?.stop()
            if let engine {
                var owned: [AVAudioNode] = [master, trim]
                if let limiter { owned.append(limiter) }
                owned += buses.values.map { $0 as AVAudioNode }
                owned += decks.values.joined().flatMap { [$0.player as AVAudioNode, $0.fade] }
                for node in owned where node.engine === engine { engine.detach(node) }
            }
            engine = nil
            limiter = nil
            decks = [:]
            buses = [:]
            isRunning = false
            isPaused = false
        }
        queue.sync(execute: work)
    }

    /// Whether the graph has been released (tests).
    var isShutDown: Bool { queue.sync { engine == nil } }

    // MARK: Tracks

    /// Starts `request` on its layer's idle deck, crossfading from what plays.
    func play(_ request: TrackRequest, crossfade: TimeInterval) {
        perform { [self] in
            guard let engine, let pair = decks[request.layer] else { return }
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: request.url) } catch {
                notify { [onFailure] in onFailure?(EngineError.unreadableFile) }
                return
            }
            let t = now()
            let incoming = pair.first { !$0.isActive } ?? pair.min { $0.ramp.value(at: t) < $1.ramp.value(at: t) }!
            for deck in pair where deck !== incoming && deck.isActive {
                deck.ramp = GainRamp(from: deck.ramp.value(at: t), to: 0, start: t, duration: max(crossfade, 0.05),
                                     shape: .equalPower)
            }
            stopDeck(incoming)
            if incoming.format != file.processingFormat {
                // Only an idle deck is rewired.
                engine.disconnectNodeOutput(incoming.player)
                engine.connect(incoming.player, to: incoming.fade, format: file.processingFormat)
                incoming.format = file.processingFormat
            }
            incoming.file = file
            incoming.trackID = request.id
            incoming.loop = request.loop
            incoming.tailStart = request.tailStart
            incoming.tailNotified = false
            incoming.trackGain = request.gain
            incoming.ramp = GainRamp(from: 0, to: request.gain, start: t, duration: max(crossfade, 0.05),
                                     shape: .equalPower)
            schedule(incoming, from: 0)
            if isRunning, !isPaused { incoming.player.play() }
            tick()
        }
    }

    /// Fades a layer out to silence.
    func stop(_ layer: Layer, fadeOut: TimeInterval) {
        perform { [self] in
            let t = now()
            for deck in decks[layer] ?? [] where deck.isActive {
                deck.ramp = GainRamp(from: deck.ramp.value(at: t), to: 0, start: t, duration: max(fadeOut, 0.05),
                                     shape: .equalPower)
            }
            tick()
        }
    }

    /// The track playing (fully faded in or fading in) on a layer.
    func currentTrack(_ layer: Layer) -> String? {
        queue.sync { decks[layer]?.first { $0.isActive && $0.ramp.to > 0 }?.trackID }
    }

    private func schedule(_ deck: Deck, from frame: AVAudioFramePosition) {
        guard let file = deck.file else { return }
        deck.generation += 1
        let generation = deck.generation
        let length = file.length
        let start = max(0, min(frame, length - 1))
        deck.startFrame = start
        deck.savedFrame = start
        guard length > 0 else { return }
        let first = AVAudioFrameCount(length - start)
        if deck.loop {
            // Two iterations always queued: the next is scheduled as one is
            // consumed, so the loop seam is sample-continuous.
            deck.player.scheduleSegment(file, startingFrame: start, frameCount: first, at: nil,
                                        completionCallbackType: .dataConsumed) { [weak self, weak deck] _ in
                self?.queue.async { if let deck { self?.loopConsumed(deck, generation) } }
            }
            deck.player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(length), at: nil,
                                        completionCallbackType: .dataConsumed) { [weak self, weak deck] _ in
                self?.queue.async { if let deck { self?.loopConsumed(deck, generation) } }
            }
        } else {
            deck.player.scheduleSegment(file, startingFrame: start, frameCount: first, at: nil,
                                        completionCallbackType: .dataPlayedBack) { [weak self, weak deck] _ in
                self?.queue.async { if let deck { self?.pieceEnded(deck, generation) } }
            }
        }
    }

    private func loopConsumed(_ deck: Deck, _ generation: Int) {
        guard generation == deck.generation, deck.loop, let file = deck.file, isRunning else { return }
        deck.player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil,
                                    completionCallbackType: .dataConsumed) { [weak self, weak deck] _ in
            self?.queue.async { if let deck { self?.loopConsumed(deck, generation) } }
        }
    }

    private func pieceEnded(_ deck: Deck, _ generation: Int) {
        guard generation == deck.generation, let id = deck.trackID,
              let engine, engine.isRunning || isOffline else { return }
        let layer = decks.first { $0.value.contains { $0 === deck } }?.key ?? .music
        let wasAudible = deck.ramp.to > 0
        stopDeck(deck)
        if wasAudible { notify { [onTrackEnded] in onTrackEnded?(layer, id) } }
    }

    private func stopDeck(_ deck: Deck) {
        deck.generation += 1
        if deck.isActive { deck.player.stop() }
        deck.file = nil
        deck.trackID = nil
        deck.tailStart = nil
        deck.ramp = .hold(0)
        deck.fade.outputVolume = 0
    }

    private func savePosition(_ deck: Deck) {
        guard let file = deck.file, let render = deck.player.lastRenderTime, render.isSampleTimeValid,
              let time = deck.player.playerTime(forNodeTime: render) else { return }
        let played = deck.startFrame + time.sampleTime
        deck.savedFrame = deck.loop ? played % max(file.length, 1) : min(played, file.length)
    }

    // MARK: Levels

    func setVolume(_ layer: Layer, slider: Double, duration: TimeInterval = 0.15) {
        perform { [self] in
            let t = now()
            let current = userGain[layer]!.value(at: t)
            userGain[layer] = GainRamp(from: current, to: VolumeTaper.gain(slider), start: t, duration: duration,
                                       shape: .decibels)
            tick()
        }
    }

    /// Narration is speaking (true) or silent (false): ducks music and, a little, ambience.
    func setNarrationAudible(_ audible: Bool) {
        perform { [self] in
            let t = now()
            musicDuck.setAudible(audible, at: t)
            ambienceDuck.setAudible(audible, at: t)
            tick()
        }
    }

    func setDuckingDepth(music: Double, ambience: Double = -4) {
        perform { [self] in
            musicDuck.depth = music
            ambienceDuck.depth = ambience
        }
    }

    /// Peak of the narration playing alongside, or nil when none is.
    func setNarrationPeak(_ peak: Float?) {
        perform { [self] in
            let t = now()
            let target = Double(peak.map(Headroom.ceiling(narrationPeak:)) ?? 0.89)
            ceilingRamp = GainRamp(from: ceilingRamp.value(at: t), to: target, start: t, duration: 0.2, shape: .decibels)
            tick()
        }
    }

    /// Another app's audio asks secondary audio to be quiet (iOS hint).
    func setMusicSilenced(_ silenced: Bool) {
        perform { [self] in
            let t = now()
            silenceRamp = GainRamp(from: silenceRamp.value(at: t), to: silenced ? 0.0001 : 1, start: t,
                                   duration: 1.5, shape: .decibels)
            tick()
        }
    }

    // MARK: Recovery

    /// The system stopped the engine to change the output (headphones,
    /// AirPlay, a new Mac output device): restart where each deck was.
    private func restartAfterConfigurationChange() {
        guard let engine, isRunning, !isPaused else { return }
        for deck in decks.values.joined() where deck.isActive {
            deck.player.stop()
        }
        do { try engine.start() } catch {
            isRunning = false
            notify { [onFailure] in onFailure?(error) }
            return
        }
        for deck in decks.values.joined() where deck.isActive {
            schedule(deck, from: deck.savedFrame)
            deck.player.play()
        }
        let t = now()
        masterRamp = GainRamp(from: 0, to: 1, start: t, duration: 1, shape: .equalPower)
        tick()
    }

    /// The media server restarted: every node is gone. Build a new graph and
    /// put the tracks back where they were.
    private func rebuildAfterReset() {
        let wasRunning = isRunning && !isPaused
        let saved: [(Layer, String?, URL?, Bool, TimeInterval?, Double, AVAudioFramePosition, GainRamp)] =
            Layer.allCases.flatMap { layer in
                (decks[layer] ?? []).filter(\.isActive).map {
                    (layer, $0.trackID, $0.file?.url, $0.loop, $0.tailStart, $0.trackGain, $0.savedFrame, $0.ramp)
                }
            }
        engine?.stop()
        engine = nil
        buildGraph()
        for (layer, id, url, loop, tail, gain, frame, ramp) in saved {
            guard let id, let url, let file = try? AVAudioFile(forReading: url),
                  let deck = decks[layer]?.first(where: { !$0.isActive }), let engine else { continue }
            engine.disconnectNodeOutput(deck.player)
            engine.connect(deck.player, to: deck.fade, format: file.processingFormat)
            deck.format = file.processingFormat
            deck.file = file
            deck.trackID = id
            deck.loop = loop
            deck.tailStart = tail
            deck.trackGain = gain
            deck.ramp = ramp
            schedule(deck, from: frame)
        }
        isRunning = false
        if wasRunning {
            do {
                try engine?.start()
                isRunning = true
                for deck in decks.values.joined() where deck.isActive { deck.player.play() }
                let t = now()
                masterRamp = GainRamp(from: 0, to: 1, start: t, duration: 1, shape: .equalPower)
                tick()
            } catch {
                notify { [onFailure] in onFailure?(error) }
            }
        }
    }

    // MARK: Offline rendering (tests)

    /// Renders `seconds` of output, running the automation every 10 ms of
    /// rendered audio exactly as the realtime timer would.
    func render(seconds: Double) throws -> AVAudioPCMBuffer {
        guard case .offline(let rate) = mode else { throw EngineError.cannotStart }
        let total = AVAudioFrameCount(seconds * rate)
        let format = queue.sync { engine?.manualRenderingFormat }
        guard let format, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            throw EngineError.cannotStart
        }
        let block = AVAudioFrameCount(rate / 100)
        var done: AVAudioFrameCount = 0
        while done < total {
            let count = min(block, total - done)
            // One queue turn per block: completions queued during the last
            // block (loop scheduling) run before the next one renders.
            let chunk: AVAudioPCMBuffer? = try queue.sync {
                tick()
                guard let engine, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
                let status = try engine.renderOffline(count, to: chunk)
                guard status == .success else { return nil }
                renderedFrames += AVAudioFramePosition(chunk.frameLength)
                return chunk
            }
            flushCallbacks()
            guard let chunk else { throw EngineError.cannotStart }
            for channel in 0..<Int(format.channelCount) {
                output.floatChannelData![channel].advanced(by: Int(done))
                    .update(from: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
            }
            done += chunk.frameLength
            output.frameLength = done
        }
        return output
    }

    /// Simulates the system stopping and restarting the engine (tests).
    func simulateConfigurationChange() {
        queue.sync {
            for deck in decks.values.joined() where deck.isActive { savePosition(deck) }
            restartAfterConfigurationChangeOffline()
        }
    }

    private func restartAfterConfigurationChangeOffline() {
        for deck in decks.values.joined() where deck.isActive {
            deck.player.stop()
            schedule(deck, from: deck.savedFrame)
            deck.player.play()
        }
        let t = now()
        masterRamp = GainRamp(from: 0, to: 1, start: t, duration: 1, shape: .equalPower)
    }

    /// Current file position of a layer's audible deck (tests).
    func position(_ layer: Layer) -> AVAudioFramePosition? {
        queue.sync {
            guard let deck = decks[layer]?.first(where: { $0.isActive && $0.ramp.to > 0 }) else { return nil }
            savePosition(deck)
            return deck.savedFrame
        }
    }
}
