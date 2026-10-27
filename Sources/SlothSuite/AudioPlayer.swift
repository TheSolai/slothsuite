import AVFoundation
import Cocoa
import Foundation

/// Plays the audio the voice service makes.
///
/// The audio is made in pieces. A long chapter is too long for one
/// request, and even when it is not, making the whole thing before playing
/// any of it would mean a wait before the first word. So the audio is
/// made a piece at a time and played as it arrives: the reader hears the
/// first words of a chapter in a few seconds, and the rest is made while
/// the earlier part is being read.
final class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    /// What the player is doing right now.
    enum State: Equatable {
        case idle
        case speaking
        case queued(Int)
    }

    /// Posted when the player changes what it is doing.
    ///
    /// A notification rather than a callback: there can be a reader in the
    /// suite and a reader in the pop-out window, and both have to hear it.
    static let stateChanged = Notification.Name("SlothSuite.audioPlayerStateChanged")

    /// What the player is doing.
    private(set) var state: State = .idle

    /// Is anything being read aloud?
    ///
    /// The interface asks this to know whether to offer a way to stop.
    var isActive: Bool { state != .idle }

    /// The piece being played.
    private var player: AVAudioPlayer?

    /// The texts still to be read.
    private var texts: [String] = []

    /// Which text is being made into audio.
    private var textIndex = 0

    /// Which piece of that text is being made.
    private var pieceIndex = 0

    /// Audio that has been made and is waiting to be played.
    private var pending: [AVAudioPlayer] = []

    /// Whether something is playing right now.
    private var playing = false

    /// Whether a piece is being made right now.
    ///
    /// Only one request is ever in flight: the pieces have to arrive in
    /// the order they were asked for, and two requests at once would not
    /// promise that.
    private var making = false

    /// The count of what has been asked for.
    ///
    /// A stop throws the count away, so the work of a reading that has
    /// ended can never be mistaken for the work of the next one.
    private var generation = 0

    /// How many pieces may be waiting.
    ///
    /// Two is enough to keep the reading going without a gap, and small
    /// enough that the audio waiting to be played does not fill the
    /// machine's memory.
    private static let bufferLimit = 2

    private override init() {
        super.init()
    }

    var isSpeaking: Bool { player?.isPlaying ?? false }

    // MARK: - Reading

    /// Read one piece of text aloud.
    func speak(_ text: String, label: String = "") {
        speakAll([text], labels: [label])
    }

    /// Read several pieces of text one after another.
    ///
    /// `labels` names each piece — "Chapter 3 of 10" rather than a
    /// spinner. Nothing shows the label yet, but the caller knows what it
    /// is reading, so the name is taken rather than refused.
    func speakAll(_ texts: [String], labels: [String] = []) {
        stop()
        generation += 1

        let usable = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else {
            setState(.idle)
            return
        }

        self.texts = usable
        textIndex = 0
        pieceIndex = 0
        setState(.queued(1))
        makeNextPiece(generation: generation)
    }

    /// Stop everything.
    func stop() {
        generation += 1
        texts.removeAll()
        pending.removeAll()
        textIndex = 0
        pieceIndex = 0
        playing = false
        making = false
        player?.stop()
        player = nil
        setState(.idle)
    }

    // MARK: - Making the audio

    /// Ask for the next piece of audio.
    ///
    /// Only one piece is being made at a time, and the next one is asked
    /// for as soon as there is room for it. That is what makes a long
    /// chapter start playing in a few seconds rather than after the whole
    /// chapter has been made.
    private func makeNextPiece(generation: Int) {
        guard generation == self.generation else { return }
        guard !making else { return }
        guard pending.count < Self.bufferLimit else { return }
        guard textIndex < texts.count else { return }

        let text = texts[textIndex]
        let count = VoiceService.shared.pieceCount(for: text)
        guard pieceIndex < count else {
            // This text has been made. Move on to the next one.
            textIndex += 1
            pieceIndex = 0
            if textIndex < texts.count { setState(.queued(textIndex + 1)) }
            makeNextPiece(generation: generation)
            return
        }

        let index = pieceIndex
        pieceIndex += 1
        making = true

        VoiceService.shared.makePiece(of: text, at: index) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.making = false
                switch result {
                case .success(let data):
                    self.addToBuffer(data)
                case .failure(let error):
                    Log.shared.write("could not make the audio: \(error)")
                }
                self.playNextPiece(generation: generation)
                self.makeNextPiece(generation: generation)
            }
        }
    }

    /// Put a piece of audio in the buffer, ready to play.
    private func addToBuffer(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            // Prepared now, so that the next piece starts the moment the
            // one before it ends rather than a moment after.
            player.prepareToPlay()
            pending.append(player)
        } catch {
            Log.shared.write("could not prepare the audio: \(error)")
        }
    }

    /// Play the next piece, if there is one and nothing is playing.
    private func playNextPiece(generation: Int) {
        guard generation == self.generation else { return }
        guard !playing else { return }

        guard !pending.isEmpty else {
            // Nothing to play yet. Either more is on its way, or it is all
            // over.
            if !making { finishIfOver() }
            makeNextPiece(generation: generation)
            return
        }

        let next = pending.removeFirst()
        next.play()
        player = next
        playing = true
        setState(.speaking)
        // Keep the buffer topped up while this one is being read.
        makeNextPiece(generation: generation)
    }

    /// Nothing left to read and nothing left to play: the reading is over.
    private func finishIfOver() {
        guard textIndex >= texts.count, pending.isEmpty, !playing, !making else { return }
        setState(.idle)
    }

    // MARK: - Internals

    /// Record what the player is doing, and tell the interface.
    ///
    /// The state belongs to the main thread. The player hears a chapter
    /// finish on its own audio thread, and a notification posted from there
    /// would run the interface's handlers off the main thread — where they
    /// would be touching buttons that AppKit says may only be touched from
    /// the main thread. So the change is taken across first.
    private func setState(_ new: State) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setState(new) }
            return
        }
        state = new
        NotificationCenter.default.post(name: AudioPlayer.stateChanged, object: self)
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    /// When one piece finishes, the next one starts.
    ///
    /// The player hears this on its own audio thread, and the queue belongs
    /// to the main thread, so the step across happens here rather than
    /// somewhere deeper down.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playing = false
            self.player = nil
            self.playNextPiece(generation: self.generation)
            self.makeNextPiece(generation: self.generation)
            self.finishIfOver()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Log.shared.write("audio decode error: \(error?.localizedDescription ?? "unknown")")
    }
}
