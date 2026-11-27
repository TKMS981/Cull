import SwiftUI

/// Elapsed / total time and a draggable scrubber along the bottom of a playing video card.
///
/// The deck's swipe runs as a simultaneous gesture over the whole card, so it also
/// sees drags that start here. The bar reports scrubbing through `onScrubbingChange`
/// from the very first touch (minimum distance 0, before the swipe's 2 pt), and the
/// deck fences that drag off: the card stays put and nothing is decided.
struct VideoSeekBar: View {
    let playback: VideoPlayback
    var onScrubbingChange: (Bool) -> Void = { _ in }

    /// Resets even when the system cancels the drag, so scrubbing can't get stuck on.
    @GestureState private var isTouching = false
    /// A finger anywhere on the bar (time labels included): the deck must not take
    /// the drag as a swipe even when it doesn't start on the track.
    @GestureState private var isTouchingBar = false

    private var fraction: Double {
        guard playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            timeText(playback.currentTime)
            track
            timeText(playback.duration)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($isTouchingBar) { _, touching, _ in touching = true }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: playback.isScrubbing || isTouchingBar) { _, fenced in onScrubbingChange(fenced) }
        .onChange(of: isTouching) { _, touching in
            if !touching { playback.endScrubbing() }
        }
        .onDisappear {
            playback.endScrubbing()
            onScrubbingChange(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("再生位置"))
        .accessibilityValue(Text("\(Self.format(playback.currentTime)) / \(Self.format(playback.duration))"))
        .accessibilityAdjustableAction { direction in
            let step: Double = 5
            switch direction {
            case .increment: playback.scrub(to: playback.currentTime + step)
            case .decrement: playback.scrub(to: playback.currentTime - step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("videoSeekBar")
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = playback.isScrubbing
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: active ? 8 : 4)
                Capsule().fill(.white)
                    .frame(width: width * fraction, height: active ? 8 : 4)
                Circle().fill(.white)
                    .frame(width: active ? 18 : 12, height: active ? 18 : 12)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: width * fraction - (active ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        if !playback.isScrubbing { playback.beginScrubbing() }
                        let position = min(max(value.location.x / width, 0), 1)
                        playback.scrub(to: position * playback.duration)
                    }
                    .onEnded { _ in playback.endScrubbing() }
            )
            .animation(.snappy(duration: 0.15), value: active)
        }
        // Tall enough to grab comfortably; the visible track is thin.
        .frame(height: 32)
    }

    private func timeText(_ seconds: Double) -> some View {
        Text(verbatim: Self.format(seconds))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 1)
    }

    static func format(_ seconds: Double) -> String {
        Duration.seconds(max(seconds.isFinite ? seconds : 0, 0)).formatted(.time(pattern: .minuteSecond))
    }
}
