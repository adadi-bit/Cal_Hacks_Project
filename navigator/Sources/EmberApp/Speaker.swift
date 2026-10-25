import Foundation
import AVFoundation
import EmberCore

/// Voice out. Lookup order (CONTRACTS.md "Audio hashing"):
/// client clone dir -> audio/<sha1>.mp3 -> fragment composition (every fragment cached) ->
/// Cartesia streaming (online, 500 ms budget) -> AVSpeechSynthesizer at rate 0.45. Never silent.
/// A new utterance stops the current clip; `replay()` says the last batch again. Every spoken string is published
/// in `currentText` so the screen shows it.
@MainActor
public final class Speaker: NSObject, ObservableObject {
    public static let appleRate: Float = 0.45
    public static let cartesiaBudgetS = 0.5

    @Published public private(set) var currentText = ""
    @Published public private(set) var lastSource = ""
    /// "slower": cached clips play at 0.85x (time-stretched), Apple TTS slows to match.
    @Published public var slower = false
    public static let normalVolume: Float = 0.85
    @Published public var volume: Float = Speaker.normalVolume

    var config: SharedConfig?
    var audioDir: URL?
    var clientId: String?
    var cartesia: CartesiaStream?
    var voiceId: String?
    var online = false

    private var lastBatch: [Utterance] = []
    private var generation = 0 { didSet { liveGeneration.set(generation) } }
    private let liveGeneration = SharedCounter()
    private var player: AVAudioPlayer?
    private var playerDone: CheckedContinuation<Void, Never>?
    private let synth = AVSpeechSynthesizer()
    private var synthDone: CheckedContinuation<Void, Never>?
    private var synthId: ObjectIdentifier?

    public override init() {
        super.init()
        synth.delegate = self
    }

    func configure(bundle: EmberBundle?, clientId: String?) {
        config = bundle?.config
        audioDir = bundle?.audioDir
        self.clientId = clientId
    }

    /// Speak a batch in order; interrupts whatever is playing.
    public func speak(_ batch: [Utterance]) {
        guard !batch.isEmpty else { return }
        generation += 1
        let gen = generation
        halt()
        lastBatch = batch
        currentText = batch[0].text
        Task { @MainActor in
            for u in batch {
                guard gen == self.generation else { return }
                self.currentText = u.text
                await self.playOne(u, gen: gen)
            }
        }
    }

    public func replay() { speak(lastBatch) }

    public func stop() {
        generation += 1
        halt()
    }

    private func halt() {
        player?.stop()
        player = nil
        playerDone?.resume()
        playerDone = nil
        synthId = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synthDone?.resume()
        synthDone = nil
        cartesia?.stop()
    }

    // MARK: lookup

    func clipURL(_ text: String, in dir: URL?) -> URL? {
        guard let dir else { return nil }
        let u = dir.appendingPathComponent("\(Hashing.clipKey(text)).mp3")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var cloneDir: URL? {
        guard let audioDir, let clientId else { return nil }
        return audioDir.appendingPathComponent("clients/\(clientId)")
    }

    /// Full-string clip: the client's cloned voice first, then the default voice.
    func fullClip(_ text: String) -> URL? {
        clipURL(text, in: cloneDir) ?? clipURL(text, in: audioDir)
    }

    /// phrases.json fragments ("Keep going on {street} for", "{n}", "blocks.") + number clips, all from one voice.
    func fragmentClips(_ u: Utterance) -> [URL]? {
        guard let t = u.template, let parts = config?.phrases.fragments[t] else { return nil }
        let texts = parts.map { SharedConfig.format($0, u.vars) }
        for dir in [cloneDir, audioDir] {
            let urls = texts.map { clipURL($0, in: dir) }
            if urls.allSatisfy({ $0 != nil }) { return urls.compactMap { $0 } }
        }
        return nil
    }

    private func playOne(_ u: Utterance, gen: Int) async {
        if let url = fullClip(u.text) {
            lastSource = "cached"
            await playFile(url)
            return
        }
        if let urls = fragmentClips(u) {
            lastSource = "fragments"
            for url in urls {
                guard gen == generation else { return }
                await playFile(url)
            }
            return
        }
        if online, let c = cartesia, let voice = voiceId, let cfg = config {
            let text = Hashing.forCartesia(u.text, pronunciation: cfg.pronunciation)
            let live = liveGeneration
            let ok = await c.speak(text, voiceId: voice, budget: Speaker.cartesiaBudgetS) { live.get() == gen }
            if ok { lastSource = "cartesia"; return }
            guard gen == generation else { return }
        }
        lastSource = "apple"
        await speakApple(u.text)
    }

    private func playFile(_ url: URL) async {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return await speakAppleFallbackForBadClip(url) }
        p.delegate = self
        p.enableRate = true
        p.rate = slower ? 0.85 : 1.0
        p.volume = volume
        player = p
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            playerDone = c
            if !p.play() {
                playerDone = nil
                c.resume()
            }
        }
    }

    /// A corrupt clip must not leave silence: say the text with Apple TTS instead.
    private func speakAppleFallbackForBadClip(_ url: URL) async {
        await speakApple(currentText)
    }

    private func speakApple(_ text: String) async {
        let u = AVSpeechUtterance(string: text)
        u.rate = slower ? Speaker.appleRate * 0.85 : Speaker.appleRate
        u.volume = volume
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            synthDone = c
            synthId = ObjectIdentifier(u)
            synth.speak(u)
        }
    }
}

extension Speaker: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let p = player, ObjectIdentifier(p) == id else { return }
        playerDone?.resume()
        playerDone = nil
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.synthFinished(id) }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.synthFinished(id) }
    }

    private func synthFinished(_ id: ObjectIdentifier) {
        guard synthId == id else { return }
        synthId = nil
        synthDone?.resume()
        synthDone = nil
    }
}

final class SharedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
