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

    /// The drag in progress, tied to the card it started on. `nil` at rest.
    @State private var drag: DeckDrag?
    /// True while a finger is on the card. SwiftUI resets it even when it cancels the
    /// gesture without calling `onEnded`, which is how a cancelled drag is cleaned up.
    @GestureState private var isTouching = false
    @State private var departing: [Departing] = []
    /// A two-finger pinch is in progress on the top card.
    @State private var isPinching = false

    /// A card flying off. Its pose is fixed at the moment of the throw and never
    /// reads the live drag, so the next card's drag can't steer it.
    private struct Departing {
        let item: CullItem
        let pose: CardPose
        /// Distinguishes repeated throws of the same card (after an undo).
        let throwID: Int
    }

    @State private var throwCount = 0

    private enum Role: Equatable {
        case waiting(Int)
        case top
        case departing(CardPose)
    }

    private struct Layer: Identifiable {
        let item: CullItem
        let role: Role
        /// One view identity per asset, whatever its role: waiting → top → departing.
        var id: String { item.id }
    }

    /// The top card's live offset: only a drag that started on this very card moves it.
    private var topOffset: CGSize {
        guard let drag, drag.itemID == current.id else { return .zero }
        return drag.offset
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(layers) { layer in
                    card(layer, size: proxy.size)
                }
            }
            .onAppear { onSizeChange(proxy.size) }
            .onChange(of: proxy.size) { _, size in onSizeChange(size) }
            .onChange(of: throwRequest) { _, request in
                guard let request else { return }
                throwRequest = nil
                throwCard(request.decision, size: proxy.size)
            }
            // A new top card (throw, undo, outside library change) never inherits a drag.
            .onChange(of: current.id) { _, id in
                if drag?.itemID != id { resetDrag() }
            }
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                // A cancelled gesture skips `onEnded`. Check after this update, by which
                // time a normal release has already thrown or settled the card.
                Task { @MainActor in
                    if !isTouching, drag != nil { snapBack() }
                }
            }
        }
    }

    /// Back to front: waiting cards, the top card, then any cards still flying off.
    private var layers: [Layer] {
        var result = upcoming.enumerated().reversed().map { Layer(item: $1, role: .waiting($0)) }
        result.append(Layer(item: current, role: .top))
        // An undo can bring a departing card back; it then shows only in its live role.
        let live = Set(result.map(\.id))
        result += departing.filter { !live.contains($0.item.id) }.map { Layer(item: $0.item, role: .departing($0.pose)) }
        return result
    }

    // MARK: Card

    private func card(_ layer: Layer, size: CGSize) -> some View {
        let width = size.width
        let isTop = layer.role == .top
        let depth: CGFloat
        let offset: CGSize
        let degrees: Double
        let zIndex: Double
        switch layer.role {
        case .waiting(let index):
            depth = CGFloat(index + 1) - progress(topOffset.width, width: width)
            offset = CGSize(width: 0, height: 24 * depth)
            degrees = 0
            zIndex = -Double(index + 1)
        case .top:
            depth = 0
            offset = topOffset
            degrees = SwipeRules.tilt(offsetX: offset.width, width: width)
            zIndex = 0
        case .departing(let pose):
            depth = 0
            offset = pose.offset
            degrees = pose.degrees
            zIndex = 1
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
        .rotationEffect(.degrees(degrees), anchor: .bottom)
        .zIndex(zIndex)
        .allowsHitTesting(isTop)
        // Simultaneous, not `.gesture`: a parent's plain gesture waits for the card's own
        // tap / double-tap / pinch to fail first, which on a device lets the finger travel
        // well past the tap tolerance before the card starts moving. Running alongside them,
        // the swipe tracks from the first couple of points. Pinches are fenced off below.
        .simultaneousGesture(swipeGesture(for: layer.item.id, size: size), isEnabled: isTop && !isZoomed)
        .accessibilityHidden(!isTop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(layer.item.asset.accessibilityKind))
        .accessibilityValue(isZoomed ? "zoomed" : "fit")
        .accessibilityIdentifier(isTop ? "mediaCard" : "mediaCardInactive")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "保持") { throwCard(.keep, size: size) }
        .accessibilityAction(named: "ゴミ箱に移動") { throwCard(.trash, size: size) }
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

    /// The swipe for the card `itemID`. Callbacks from a card that is no longer on top
    /// (a late event after a throw or undo) are ignored.
    private func swipeGesture(for itemID: String, size: CGSize) -> some Gesture {
        let width = size.width
        return DragGesture(minimumDistance: SwipeRules.minimumDistance, coordinateSpace: .global)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard itemID == current.id else { return }
                let previous = drag?.itemID == itemID ? drag : nil
                // A pinch running alongside (or one that zoomed in) takes over: park the card.
                let next = DeckDrag.next(previous, itemID: itemID, translation: value.translation,
                                         width: width, fenced: isPinching || isZoomed)
                if previous?.axis == nil, next.axis == .vertical {
                    // The few points of sideways travel before the lock settle back quickly.
                    withAnimation(.snappy(duration: 0.15)) { drag = next }
                } else if next.fenced {
                    if previous?.offset != .zero { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { drag = next } }
                    else { drag = next }
                } else {
                    // 1:1 with the finger: no animation while dragging.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { drag = next }
                }
                if next.armed != previous?.armed, next.armed != nil { onArmed() }
            }
            .onEnded { value in
                guard itemID == current.id, let ended = drag, ended.itemID == itemID else { return }
                guard !isZoomed, !ended.fenced, !isPinching else { return snapBack() }
                let outcome = SwipeRules.outcome(
                    translation: value.translation,
                    predicted: value.predictedEndTranslation,
                    axis: ended.axis,
                    width: width
                )
                switch outcome {
                case .decide(let decision):
                    throwCard(decision, size: size)
                case .info:
                    snapBack()
                    onInfo()
                case .cancel:
                    snapBack()
                }
            }
    }

    private func snapBack() {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { drag = nil }
    }

    /// Drops any drag state at once, with no animation (the top card changed under it).
    private func resetDrag() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = nil }
    }

    /// Left (keep) flies the card off to the left; right (trash) to the right.
    /// The decision is recorded immediately; only the visual flight is animated.
    private func throwCard(_ decision: Decision, size: CGSize) {
        let item = current
        let pose = SwipeRules.throwPose(decision, release: topOffset, size: size)
        throwCount += 1
        let throwID = throwCount
        departing.removeAll { $0.item.id == item.id }
        withAnimation(.smooth(duration: 0.28)) {
            departing.append(Departing(item: item, pose: pose, throwID: throwID))
            drag = nil
            onDecide(decision)
        } completion: {
            departing.removeAll { $0.throwID == throwID }
        }
    }
}
