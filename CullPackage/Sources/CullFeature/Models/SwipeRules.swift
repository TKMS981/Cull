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
/// - The card follows the finger 1:1 from `minimumDistance`.
/// - After `lockDistance` the drag is locked to one axis for the rest of the gesture,
///   so a vertical drag can never turn into keep / trash (and vice versa).
/// - Keep / trash commits only past `commitFraction` of the card width, or on a real
///   flick in the same direction; anything less springs back to the centre.
nonisolated enum SwipeRules {
    static let minimumDistance: CGFloat = 8
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
