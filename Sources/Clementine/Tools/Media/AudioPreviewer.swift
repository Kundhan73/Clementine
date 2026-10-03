import AVFoundation
import ClementineCore
import SwiftUI

/// Renders a short preview with ffmpeg into a temporary file and plays it.
/// Everything is dropped on `stop()`.
@MainActor
final class AudioPreviewer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, rendering, playing }

    @Published private(set) var state: State = .idle
    private var player: AVAudioPlayer?
    private var work: TempDirectory?
    private var generation = 0

    /// `render` writes the preview into the URL it's given.
    func play(from start: Double = 0, render: @escaping @Sendable (URL) async throws -> Void) {
        stop()
        generation += 1
        let token = generation
        state = .rendering
        Task {
            do {
                let work = try TempDirectory(prefix: "clementine-preview")
                let out = work.file("preview.m4a")
                try await render(out)
                guard token == generation else { work.remove(); return }
                let player = try AVAudioPlayer(contentsOf: out)
                player.delegate = self
                player.currentTime = max(0, min(start, player.duration - 0.5))
                player.play()
                self.work = work
                self.player = player
                state = .playing
            } catch {
                if token == generation { state = .idle }
            }
        }
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        work?.remove()
        work = nil
        state = .idle
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.stop() }
        }
    }
}

extension MediaAnalysis {
    /// The first `seconds` of the sound as WAV (quick input for previews).
    static func excerpt(_ input: URL, seconds: Double, to output: URL) async throws {
        try await MediaEngine.run([FFmpegAttempt("excerpt", output: ["-t", String(format: "%.1f", seconds), "-map", "0:a:0",
                                                                     "-vn", "-c:a", "pcm_s16le"])],
                                  input: input, output: output, duration: seconds, failure: "Couldn't prepare a preview.")
    }
}
