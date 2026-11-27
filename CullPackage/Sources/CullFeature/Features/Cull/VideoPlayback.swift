import AVFoundation
import Observation
import Photos

/// The looping player behind one video card, plus its time and scrubbing state.
///
/// A reference type on purpose: `start(asset:)` awaits the `AVAsset`, and a view
/// struct captured by a `.task` would still see the `isMuted` value from when the
/// task began. Here the player is always created with the current `isMuted`, and
/// later changes reach it through `didSet`.
@Observable
final class VideoPlayback {
    private(set) var player: AVQueuePlayer?
    var isReady = false
    /// Seconds into the clip (the scrub position while scrubbing).
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isScrubbing = false

    var isMuted = true {
        didSet { player?.isMuted = isMuted }
    }

    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: Double?

    func start(asset: PHAsset) async {
        guard player == nil else { return }
        duration = asset.duration
        guard let avAsset = await ImageLoader.shared.videoAsset(for: asset), !Task.isCancelled, player == nil else { return }
        let item = AVPlayerItem(asset: avAsset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = isMuted
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        timeObserver = queuePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isSeeking, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }
        player = queuePlayer
        queuePlayer.play()
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isReady = false
        isScrubbing = false
        isSeeking = false
        pendingSeek = nil
        currentTime = 0
    }

    // MARK: Scrubbing

    func beginScrubbing() {
        guard player != nil else { return }
        isScrubbing = true
        player?.pause()
    }

    /// Moves the playhead to `seconds`, chasing the finger: while a seek is in flight
    /// only the newest position is kept, so seeks never queue up behind each other.
    func scrub(to seconds: Double) {
        guard player != nil else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        pendingSeek = clamped
        if !isSeeking { seekToPending() }
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        if !isSeeking { player?.play() }
    }

    private func seekToPending() {
        guard let player, let target = pendingSeek else {
            isSeeking = false
            if !isScrubbing { player?.play() }
            return
        }
        pendingSeek = nil
        isSeeking = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in self?.seekToPending() }
        }
    }
}
