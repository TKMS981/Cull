import AVFoundation
import SwiftUI
import Synchronization

/// Owns the app's `AVAudioSession` configuration.
///
/// - Muted autoplay runs under `.ambient` + `.mixWithOthers`, so it never stops the
///   user's music.
/// - When the user turns sound on, the session switches to `.playback` and activates.
///   That category ignores the Ring/Silent switch, which is what a deliberate
///   "sound on" means. Before this, the default `.soloAmbient` category kept videos
///   silent on a device in silent mode.
/// - Turning sound off deactivates with `.notifyOthersOnDeactivation`, so audio the
///   user paused can resume.
///
/// `setCategory` and `setActive` do blocking IPC with the audio server, so they run
/// off the main actor on a serial queue (FIFO, so rapid toggles apply in order;
/// a request already superseded by a newer one is skipped).
nonisolated final class AudioSessionCoordinator: Sendable {
    static let shared = AudioSessionCoordinator()

    private let queue = DispatchQueue(label: "Cull.AudioSession", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var latest = 0
        var isAudible: Bool?
    }

    /// Sets whether media on screen should be heard. Safe to call repeatedly.
    func setAudible(_ audible: Bool) {
        let ticket = state.withLock { state -> Int in
            state.latest += 1
            return state.latest
        }
        queue.async { self.apply(audible, ticket: ticket) }
    }

    private func apply(_ audible: Bool, ticket: Int) {
        let shouldApply = state.withLock { state -> Bool in
            guard ticket == state.latest, state.isAudible != audible else { return false }
            state.isAudible = audible
            return true
        }
        guard shouldApply else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if audible {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } else {
                // Deactivating an inactive session can fail harmlessly; the category still matters.
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.ambient, mode: .default, options: .mixWithOthers)
            }
        } catch {
            // Leave the state unknown so the next request retries.
            state.withLock { $0.isAudible = nil }
        }
    }
}

extension View {
    /// Keeps the audio session audible while `audible` is true and this view is on screen.
    func audioSessionAudible(_ audible: Bool) -> some View {
        onChange(of: audible) { _, audible in
            AudioSessionCoordinator.shared.setAudible(audible)
        }
        // Also on every appearance: coming back from a pushed screen re-applies it.
        .onAppear { AudioSessionCoordinator.shared.setAudible(audible) }
        .onDisappear { AudioSessionCoordinator.shared.setAudible(false) }
    }
}
