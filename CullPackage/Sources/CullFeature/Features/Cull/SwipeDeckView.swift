import SwiftUI

/// A request from outside the deck (keep / trash buttons) to throw the top card.
struct DeckThrow: Equatable {
    let decision: Decision
    let id: Int
}

/// The swipeable card stack. Owns the drag state so finger tracking only
/// re-renders the cards, not the whole culling screen.
///
/// Every card is keyed by its asset, so a card keeps its view (and loaded image)
/// as it moves from waiting → top → flying away. A thrown card leaves as a
/// non-interactive "departing" layer: the next card is live the instant the
/// finger lifts, with no lockout while the animation plays.
struct SwipeDeckView: View {
    let current: CullItem
    /// Cards waiting behind, nearest first.
    let upcoming: [CullItem]
    @Binding var isZoomed: Bool
    @Binding var isMuted: Bool
    @Binding var throwRequest: DeckThrow?
    var onDecide: (Decision) -> Void
    var onArmed: () -> Void
    var onInfo: () -> Void
    var onSizeChange: (CGSize) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var axis: SwipeAxis?
    @State private var armed: Decision?
    @State private var departing: [Departing] = []
    /// A two-finger pinch is in progress on the top card.
    @State private var isPinching = false
    /// This drag overlapped a pinch, so it must not decide anything.
    @State private var dragSawPinch = false

    private struct Departing {
        let item: CullItem
        let offset: CGSize
    }

    private enum Role: Equatable {
        case waiting(Int)
        case top
        case departing(CGSize)
    }

    private struct Layer: Identifiable {
        let item: CullItem
        let role: Role
        var id: String { item.id }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                ForEach(layers) { layer in
                    card(layer, width: width)
                }
            }
            .onAppear { onSizeChange(proxy.size) }
            .onChange(of: proxy.size) { _, size in onSizeChange(size) }
            .onChange(of: throwRequest) { _, request in
                guard let request else { return }
                throwRequest = nil
                throwCard(request.decision, width: width)
            }
        }
    }

    /// Back to front: waiting cards, the top card, then any cards still flying off.
    private var layers: [Layer] {
        var result = upcoming.enumerated().reversed().map { Layer(item: $1, role: .waiting($0)) }
        result.append(Layer(item: current, role: .top))
        // An undo can bring a departing card back; it then shows only in its live role.
        let live = Set(result.map(\.id))
        result += departing.filter { !live.contains($0.item.id) }.map { Layer(item: $0.item, role: .departing($0.offset)) }
        return result
    }

    // MARK: Card

    private func card(_ layer: Layer, width: CGFloat) -> some View {
        let isTop = layer.role == .top
        let depth: CGFloat
        let offset: CGSize
        switch layer.role {
        case .waiting(let index):
            depth = CGFloat(index + 1) - progress(dragOffset.width, width: width)
            offset = CGSize(width: 0, height: 24 * depth)
        case .top:
            depth = 0
            offset = dragOffset
        case .departing(let flown):
            depth = 0
            offset = flown
        }
        let lean = progress(offset.width, width: width)

        return MediaCardView(
            asset: layer.item.asset,
            isActive: isTop,
            isZoomed: isTop ? $isZoomed : .constant(false),
            isMuted: isTop ? isMuted : true,
            onToggleMute: { isMuted.toggle() },
            onPinchingChange: isTop ? { isPinching = $0 } : nil
        )
        .overlay { Color.black.opacity(0.18 * depth).allowsHitTesting(false) }
        .overlay { decisionTint(offset.width, progress: lean) }
        .overlay { decisionBadge(offset.width, progress: lean) }
        .clipShape(.rect(cornerRadius: 24))
        .shadow(color: .black.opacity(depth == 0 ? 0.22 : 0), radius: 14, y: 8)
        .scaleEffect(1 - 0.05 * depth)
        .offset(offset)
        .rotationEffect(.degrees(Double(offset.width / max(width, 1)) * 12), anchor: .bottom)
        .allowsHitTesting(isTop)
        // Simultaneous, not `.gesture`: a parent's plain gesture waits for the card's own
        // tap / double-tap / pinch to fail first, which on a device lets the finger travel
        // well past the tap tolerance before the card starts moving. Running alongside them,
        // the swipe tracks from the first couple of points. Pinches are fenced off below.
        .simultaneousGesture(swipeGesture(width: width), isEnabled: isTop && !isZoomed)
        .accessibilityHidden(!isTop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(layer.item.asset.accessibilityKind))
        .accessibilityValue(isZoomed ? "zoomed" : "fit")
        .accessibilityIdentifier(isTop ? "mediaCard" : "mediaCardInactive")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "保持") { throwCard(.keep, width: width) }
        .accessibilityAction(named: "ゴミ箱に移動") { throwCard(.trash, width: width) }
        .accessibilityAction(named: "情報") { onInfo() }
    }

    /// 0 at rest, 1 once a card is past the decision threshold.
    private func progress(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(abs(x) / max(SwipeRules.threshold(width: width), 1), 1)
    }

    /// A wash of the decision's color over the card that deepens with the drag.
    @ViewBuilder
    private func decisionTint(_ x: CGFloat, progress: CGFloat) -> some View {
        if x != 0 {
            Rectangle()
                .fill((x < 0 ? Color.green : Color.red).gradient)
                .opacity(0.28 * progress)
                .allowsHitTesting(false)
        }
    }

    /// KEEP (dragging left) / TRASH (dragging right) stamps that fade and settle in with the drag.
    @ViewBuilder
    private func decisionBadge(_ x: CGFloat, progress: CGFloat) -> some View {
        if x < -Self.stampAppearsAfter {
            stamp("KEEP", systemImage: "checkmark", color: .green, angle: 12, progress: progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        } else if x > Self.stampAppearsAfter {
            stamp("TRASH", systemImage: "trash", color: .red, angle: -12, progress: progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func stamp(_ title: String, systemImage: String, color: Color, angle: Double, progress: CGFloat) -> some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) }
            .font(.title.weight(.heavy))
            .kerning(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.85), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color, lineWidth: 4))
            .rotationEffect(.degrees(angle))
            .scaleEffect(0.8 + 0.2 * progress)
            .opacity(progress)
            .padding(28)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let stampAppearsAfter: CGFloat = 8

    // MARK: Gesture

    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: SwipeRules.minimumDistance)
            .onChanged { value in
                // A pinch running alongside (or one that zoomed in) takes over: park the card.
                if isPinching { dragSawPinch = true }
                guard !isZoomed, !dragSawPinch else {
                    if dragOffset != .zero { snapBack() }
                    return
                }
                let translation = value.translation
                if axis == nil, let locked = SwipeRules.lock(translation) {
                    axis = locked
                    if locked == .vertical {
                        // The few points of sideways travel before the lock settle back quickly.
                        withAnimation(.snappy(duration: 0.15)) {
                            dragOffset = SwipeRules.cardOffset(translation, axis: locked)
                        }
                        return
                    }
                }
                // 1:1 with the finger: no animation while dragging.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = SwipeRules.cardOffset(translation, axis: axis)
                }
                let newArmed = SwipeRules.armed(translation, axis: axis, width: width)
                if newArmed != armed {
                    armed = newArmed
                    if newArmed != nil { onArmed() }
                }
            }
            .onEnded { value in
                let lockedAxis = axis
                let sawPinch = dragSawPinch || isPinching
                axis = nil
                armed = nil
                dragSawPinch = false
                guard !isZoomed, !sawPinch else { return snapBack() }
                let outcome = SwipeRules.outcome(
                    translation: value.translation,
                    predicted: value.predictedEndTranslation,
                    axis: lockedAxis,
                    width: width
                )
                switch outcome {
                case .decide(let decision):
                    throwCard(decision, width: width)
                case .info:
                    snapBack()
                    onInfo()
                case .cancel:
                    snapBack()
                }
            }
    }

    private func snapBack() {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { dragOffset = .zero }
    }

    /// Left (keep) flies the card off to the left; right (trash) to the right.
    /// The decision is recorded immediately; only the visual flight is animated.
    private func throwCard(_ decision: Decision, width: CGFloat) {
        let item = current
        let direction: CGFloat = decision == .keep ? -1 : 1
        let target = CGSize(width: direction * width * 1.5, height: dragOffset.height + 40)
        departing.removeAll { $0.item.id == item.id }
        withAnimation(.smooth(duration: 0.28)) {
            departing.append(Departing(item: item, offset: target))
            dragOffset = .zero
            onDecide(decision)
        } completion: {
            departing.removeAll { $0.item.id == item.id && $0.offset == target }
        }
    }
}
