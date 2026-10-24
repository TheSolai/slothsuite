import AVFoundation
import Cocoa
import Foundation

/// Plays the audio the Mac service synthesises.
///
/// The service returns a WAV, not playback — it hands back the bytes and
/// leaves playing them to the shell. Until this existed, the "speak"
/// buttons generated a file and threw it away, so the suite looked like it
/// could read aloud and could not.
///
/// Playback is queued so that "play every chapter" reads the chapters one
/// after another instead of piling them on top of each other.
final class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    /// What the player is doing right now.
    enum State {
        case idle
        case speaking
        case queued(Int)
    }

    /// Called whenever the state changes, so the interface can show it.
    var onStateChange: ((State) -> Void)?

    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var queueIndex = 0
    private var labels: [String] = []
    private var generation = 0

    private override init() {
        super.init()
    }

    var isSpeaking: Bool { player?.isPlaying ?? false }

    // MARK: - Single utterance

    /// Read one piece of text aloud.
    func speak(_ text: String, label: String = "") {
        stop()
        generation += 1
        speak(text, label: label, generation: generation)
    }

    /// Read several pieces of text one after another.
    ///
    /// `labels` names each piece, so the interface can show what is being
    /// read — "Chapter 3 of 10" rather than a spinner.
    func speakAll(_ texts: [String], labels: [String] = []) {
        stop()
        generation += 1

        let usable = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else {
            onStateChange?(.idle)
            return
        }

        queue = usable
        queueIndex = 0
        self.labels = labels.count == usable.count ? labels : usable.map { _ in "" }
        onStateChange?(.queued(1))
        playNext(generation: generation)
    }

    // MARK: - Stopping

    func stop() {
        generation += 1
        queue.removeAll()
        queueIndex = 0
        labels.removeAll()
        player?.stop()
        player = nil
        onStateChange?(.idle)
    }

    // MARK: - Internals

    private func playNext(generation: Int) {
        guard generation == self.generation else { return }
        guard queueIndex < queue.count else {
            player = nil
            onStateChange?(.idle)
            return
        }

        let text = queue[queueIndex]
        onStateChange?(.queued(queueIndex + 1))
        speak(text, label: queueIndex < labels.count ? labels[queueIndex] : "", generation: generation)
    }

    private func speak(_ text: String, label: String, generation: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queueIndex += 1
            playNext(generation: generation)
            return
        }

        MacServices.shared.speak(text: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }

                switch result {
                case .success(let data):
                    self.play(data: data, generation: generation)
                case .failure(let error):
                    Log.shared.write("could not synthesise audio: \(error)")
                    self.queueIndex += 1
                    self.playNext(generation: generation)
                }
            }
        }
    }

    private func play(data: Data, generation: Int) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            onStateChange?(.speaking)
        } catch {
            Log.shared.write("could not play the synthesised audio: \(error)")
            queueIndex += 1
            playNext(generation: generation)
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    /// When one piece finishes, the next one starts.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard generation == self.generation else { return }
        queueIndex += 1
        playNext(generation: generation)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Log.shared.write("audio decode error: \(error?.localizedDescription ?? "unknown")")
    }
}
