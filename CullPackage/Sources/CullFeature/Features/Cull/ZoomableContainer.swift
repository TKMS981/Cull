import SwiftUI

/// Pinch-to-zoom + pan + double-tap-to-zoom. Reports `isZoomed` upward so the
/// parent can disable swipe-to-cull and swipe-up-for-info while zoomed.
struct ZoomableContainer<Content: View>: View {
    @Binding var isZoomed: Bool
    var onSingleTap: (() -> Void)? = nil
    @ViewBuilder var content: Content

    static var maxScale: CGFloat { 6 }
    static var doubleTapScale: CGFloat { 2.5 }

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pan: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let liveScale = min(max(scale * pinch, 1), Self.maxScale)
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(liveScale)
                .offset(clamped(offset + pan, scale: liveScale, in: size))
                .contentShape(.rect)
                .gesture(magnify(in: size))
                .simultaneousGesture(panGesture(in: size), isEnabled: scale > 1)
                .onTapGesture(count: 2) { toggleZoom(in: size) }
                .onTapGesture(count: 1) { onSingleTap?() }
        }
        .clipped()
        .onChange(of: isZoomed) { _, zoomed in
            // Parent may request a reset (e.g. after an undo).
            if !zoomed && scale > 1 { reset() }
        }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onChanged { value in
                // Flip to "zoomed" as soon as the pinch opens so a concurrent drag can't cull.
                if scale * value.magnification > 1.01, !isZoomed { isZoomed = true }
            }
            .onEnded { value in
                let newScale = min(max(scale * value.magnification, 1), Self.maxScale)
                withAnimation(.spring(duration: 0.3)) {
                    scale = newScale
                    offset = newScale > 1 ? clamped(offset, scale: newScale, in: size) : .zero
                }
                isZoomed = newScale > 1
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10) // > 0 so double-tap-to-reset still recognizes while zoomed
            .updating($pan) { value, state, _ in state = value.translation }
            .onEnded { value in
                withAnimation(.interactiveSpring) {
                    offset = clamped(offset + value.translation, scale: scale, in: size)
                }
            }
    }

    private func toggleZoom(in size: CGSize) {
        withAnimation(.spring(duration: 0.3)) {
            if scale > 1 {
                scale = 1
                offset = .zero
            } else {
                scale = Self.doubleTapScale
            }
        }
        isZoomed = scale > 1
    }

    private func reset() {
        withAnimation(.spring(duration: 0.3)) {
            scale = 1
            offset = .zero
        }
    }

    private func clamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max((scale - 1) * size.width / 2, 0)
        let maxY = max((scale - 1) * size.height / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
