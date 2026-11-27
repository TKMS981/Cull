import CoreGraphics

/// Which way a drag on the card was locked to after its first few points.
nonisolated enum SwipeAxis: Sendable {
    /// Keep / trash.
    case horizontal
    /// Info (up); down does nothing.
    case vertical
}

nonisolated enum SwipeOutcome: Equatable, Sendable {
    case decide(Decision)
    case info
    case cancel
}

/// The card's swipe rules, kept free of SwiftUI so they can be unit tested.
///
/// - The card follows the finger 1:1 from `minimumDistance` (essentially the first movement).
/// - After `lockDistance` the drag is locked to one axis for the rest of the gesture,
///   so a vertical drag can never turn into keep / trash (and vice versa).
/// - Keep / trash commits only past `commitFraction` of the card width, or on a real
///   flick in the same direction; anything less springs back to the centre.
nonisolated enum SwipeRules {
    static let minimumDistance: CGFloat = 2
    static let lockDistance: CGFloat = 12
    static let commitFraction: CGFloat = 0.38
    /// A flick commits when its predicted end lands this far out (fraction of width)…
    static let flickFraction: CGFloat = 0.9
    /// …and the finger itself travelled at least this much.
    static let minimumFlickTravel: CGFloat = 40
    static let infoDistance: CGFloat = 60
    static let infoFlick: CGFloat = 180
    static let minimumInfoFlickTravel: CGFloat = 24

    static func threshold(width: CGFloat) -> CGFloat { width * commitFraction }

    /// The axis to lock to, or `nil` while the drag is still too short to tell.
    static func lock(_ translation: CGSize) -> SwipeAxis? {
        guard hypot(translation.width, translation.height) >= lockDistance else { return nil }
        return abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }

    /// Where the card sits for a finger `translation`.
    static func cardOffset(_ translation: CGSize, axis: SwipeAxis?) -> CGSize {
        switch axis {
        case nil, .horizontal:
            // Horizontal tracks the finger exactly; a little vertical give keeps it feeling held.
            CGSize(width: translation.width, height: translation.height * 0.12)
        case .vertical:
            // Rubber-band upwards only; never sideways once locked vertical.
            CGSize(width: 0, height: min(translation.height, 0) * 0.25)
        }
    }

    /// The decision a release right now would make by distance alone (for the "armed" haptic).
    static func armed(_ translation: CGSize, axis: SwipeAxis?, width: CGFloat) -> Decision? {
        guard axis == .horizontal else { return nil }
        let threshold = threshold(width: width)
        if translation.width <= -threshold { return .keep }
        if translation.width >= threshold { return .trash }
        return nil
    }

    static func outcome(translation: CGSize, predicted: CGSize, axis: SwipeAxis?, width: CGFloat) -> SwipeOutcome {
        switch axis {
        case nil:
            return .cancel
        case .horizontal:
            let dx = translation.width, px = predicted.width
            // Thrown back toward the centre (or past it) never commits.
            guard dx != 0, (dx < 0) == (px < 0) else { return .cancel }
            let threshold = threshold(width: width)
            let reached = abs(dx) >= threshold && abs(px) >= threshold
            let flicked = abs(px) >= width * flickFraction && abs(dx) >= minimumFlickTravel
            guard reached || flicked else { return .cancel }
            return .decide(dx < 0 ? .keep : .trash)
        case .vertical:
            let dy = translation.height, py = predicted.height
            if dy <= -infoDistance || (py <= -infoFlick && dy <= -minimumInfoFlickTravel) { return .info }
            return .cancel
        }
    }
}

// MARK: Card pose

/// Where a card sits and how far it leans.
nonisolated struct CardPose: Equatable, Sendable {
    var offset: CGSize
    var degrees: Double

    static let rest = CardPose(offset: .zero, degrees: 0)
}

nonisolated extension SwipeRules {
    /// The most a card ever leans, dragging or flying off.
    static let maxTilt: Double = 18
    /// Lean per card-width of horizontal travel.
    static let tiltPerWidth: Double = 12
    /// How far below its resting place a thrown card ends up.
    static let throwDrop: CGFloat = 40

    /// The lean for a card `x` points off centre. Bounded, and zero for a degenerate
    /// width, so a momentarily tiny layout can never spin the card.
    static func tilt(offsetX x: CGFloat, width: CGFloat) -> Double {
        guard width >= 1, x.isFinite else { return 0 }
        let raw = Double(x / width) * tiltPerWidth
        return min(max(raw, -maxTilt), maxTilt)
    }

    /// The final pose of a card thrown for `decision`, released at `release`.
    ///
    /// Fixed at the moment of the throw (the flying layer never reads live drag
    /// state). Keep / trash leave sideways, leaning the way they travel, and always
    /// end at or below their resting height: an upward drift at release is dropped,
    /// so a thrown card can't sail up the screen.
    static func throwPose(_ decision: Decision, release: CGSize, size: CGSize) -> CardPose {
        let width = max(size.width, 1)
        let direction: CGFloat = decision == .keep ? -1 : 1
        let y = max(release.height, 0) + throwDrop
        return CardPose(offset: CGSize(width: direction * width * 1.5, height: y), degrees: Double(direction) * maxTilt)
    }
}

// MARK: Drag tracking

/// One drag on the deck, tied to the card it started on.
///
/// A new card always starts from a fresh value, so an axis lock, armed state or
/// pinch fence from an earlier drag (including one SwiftUI cancelled without
/// calling `onEnded`) can never leak into the next card.
nonisolated struct DeckDrag: Equatable, Sendable {
    let itemID: String
    var offset: CGSize = .zero
    var axis: SwipeAxis?
    var armed: Decision?
    /// This drag overlapped a pinch (or another control's drag), so it must not move or decide.
    var fenced = false

    /// The drag after a gesture change on card `itemID`.
    static func next(
        _ previous: DeckDrag?,
        itemID: String,
        translation: CGSize,
        width: CGFloat,
        fenced: Bool
    ) -> DeckDrag {
        var drag = previous?.itemID == itemID ? previous! : DeckDrag(itemID: itemID)
        if fenced { drag.fenced = true }
        guard !drag.fenced else {
            drag.offset = .zero
            drag.armed = nil
            return drag
        }
        if drag.axis == nil { drag.axis = SwipeRules.lock(translation) }
        drag.offset = SwipeRules.cardOffset(translation, axis: drag.axis)
        drag.armed = SwipeRules.armed(translation, axis: drag.axis, width: width)
        return drag
    }
}
