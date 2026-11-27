import Photos
import SwiftUI

/// Swipe-culling screen. Left = keep, right = Cull's trash, up = info.
/// All three swipes are disabled while the card is zoomed (scale > 1).
struct CullView: View {
    let filter: CullFilter
    var sort: CullSort = .oldest
    let includeKept: Bool
    /// Cull exactly these items in this order instead of running `filter`.
    var identifiers: [String]?

    @Environment(PhotoLibraryService.self) private var library
    @Environment(DecisionStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(filter: CullFilter, sort: CullSort = .oldest, includeKept: Bool) {
        self.filter = filter
        self.sort = sort
        self.includeKept = includeKept
    }

    init(selection: AssetSelection) {
        filter = CullFilter()
        sort = .largest
        includeKept = selection.includeKept
        identifiers = selection.ids
    }

    @State private var session: CullSession?
    @State private var isZoomed = false
    @State private var isMuted = true
    @State private var infoItem: CullItem?
    @State private var showTrash = false
    /// Keep / trash button taps, handed to the deck so it can throw the card.
    @State private var deckThrow: DeckThrow?
    @State private var feedback: Feedback?

    /// One haptic event; `id` makes repeated events of the same kind distinct triggers.
    private struct Feedback: Equatable {
        enum Kind { case armed, keep, trash, skip, undo }
        let kind: Kind
        let id: Int
    }

    var body: some View {
        Group {
            if let session, session.phase == .ready {
                content(session)
            } else if let sizing = session?.sizing {
                VStack(spacing: 12) {
                    ProgressView(value: Double(sizing.done), total: Double(max(sizing.total, 1)))
                        .frame(maxWidth: 220)
                    Text("容量を計算中…")
                        .font(.headline)
                    if sizing.total > 0 {
                        Text("\(sizing.done) / \(sizing.total)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sizingProgress")
            } else {
                ProgressView("読み込み中…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .contentPopGestureDisabled()
        .toolbar {
            ToolbarItem(placement: .principal) { progressHeader }
            // Undo + trash share one Liquid Glass capsule.
            ToolbarItemGroup(placement: .topBarTrailing) {
                undoButton
                trashButton
            }
        }
        .navigationDestination(isPresented: $showTrash) {
            TrashView { restored in session?.requeue(ids: restored) }
        }
        .sheet(item: $infoItem) { item in
            AssetInfoSheet(asset: item.asset)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if let session {
                session.resumeCaching()
            } else {
                let newSession = CullSession(filter: filter, sort: sort, includeKept: includeKept, identifiers: identifiers,
                                             library: library, store: store)
                session = newSession
                await newSession.load()
            }
            for await change in library.changes() {
                session?.apply(change)
            }
        }
        .onDisappear { session?.tearDown() }
        // Background: drop PhotoKit's image cache (the player is released by its card).
        // Memory warning: drop it too, then re-warm just the next few cards.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session?.resumeCaching() } else { session?.tearDown() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            session?.tearDown()
            if scenePhase == .active { session?.resumeCaching() }
        }
        // Sound on → `.playback` (heard even in silent mode); otherwise mix quietly with other audio.
        .audioSessionAudible(!isMuted && (session?.current?.asset.hasAudio ?? false))
        .sensoryFeedback(trigger: feedback) { _, new in
            switch new?.kind {
            case .armed: .impact(weight: .medium, intensity: 0.7)
            case .keep: .impact(weight: .light)
            case .trash: .impact(weight: .heavy, intensity: 0.8)
            case .skip: .selection
            case .undo: .impact(flexibility: .soft, intensity: 0.8)
            case nil: nil
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var progressHeader: some View {
        if let session, session.total > 0 {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Text("残り \(session.remaining) / \(session.total)")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        Label { Text(session.keptCount, format: .number) } icon: { Image(systemName: "checkmark") }
                            .foregroundStyle(.green)
                        Label { Text(session.trashedCount, format: .number) } icon: { Image(systemName: "trash") }
                            .foregroundStyle(.red)
                        if session.skippedCount > 0 {
                            Label { Text(session.skippedCount, format: .number) } icon: { Image(systemName: "forward.fill") }
                                .foregroundStyle(.indigo)
                                .accessibilityIdentifier("skipTally")
                        }
                    }
                    .labelStyle(.tally)
                    .font(.caption.weight(.semibold))
                }
                .monospacedDigit()
                ProgressView(value: Double(session.decidedCount), total: Double(max(session.total, 1)))
                    .frame(width: 160)
                    .animation(.smooth, value: session.decidedCount)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("残り \(session.remaining) 件、全 \(session.total) 件")
            .accessibilityValue(Text(session.remaining, format: .number))
            .accessibilityIdentifier("progress")
        }
    }

    private var undoButton: some View {
        Button {
            undo()
        } label: {
            Label("元に戻す", systemImage: "arrow.uturn.backward")
        }
        .disabled(!(session?.canUndo ?? false))
        .accessibilityIdentifier("undoButton")
    }

    private func undo() {
        guard let session, session.canUndo else { return }
        isZoomed = false
        // Animated so a card that is still flying off glides back to the centre.
        withAnimation(.smooth(duration: 0.3)) { session.undo() }
        emit(.undo)
    }

    private func emit(_ kind: Feedback.Kind) {
        feedback = Feedback(kind: kind, id: (feedback?.id ?? 0) + 1)
    }

    private var trashButton: some View {
        Button {
            showTrash = true
        } label: {
            Image(systemName: "trash")
                .overlay(alignment: .topTrailing) {
                    if !store.trash.isEmpty {
                        Text(store.trash.count, format: .number)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: .capsule)
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .accessibilityLabel("ゴミ箱")
        .accessibilityValue(Text(store.trash.count, format: .number))
        .accessibilityIdentifier("trashButton")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ session: CullSession) -> some View {
        VStack(spacing: 16) {
            if let current = session.current {
                cardStack(session, current: current)
                controls(session, current: current)
            } else {
                finished(session)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func cardStack(_ session: CullSession, current: CullItem) -> some View {
        SwipeDeckView(
            current: current,
            upcoming: session.upcoming(2),
            isZoomed: $isZoomed,
            isMuted: $isMuted,
            throwRequest: $deckThrow,
            onDecide: { decision in
                session.decide(decision)
                let kind: Feedback.Kind = switch decision {
                case .keep: .keep
                case .trash: .trash
                case .skip: .skip
                }
                emit(kind)
                isZoomed = false
            },
            onArmed: { emit(.armed) },
            onInfo: { infoItem = session.current },
            onSizeChange: { updateCacheSize(session, $0) }
        )
    }

    private func updateCacheSize(_ session: CullSession, _ size: CGSize) {
        session.cacheTargetSize = CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    private func controls(_ session: CullSession, current: CullItem) -> some View {
        HStack(spacing: 14) {
            // Leading slot: sound toggle for media with audio, otherwise empty to keep the layout centred.
            Group {
                if current.asset.hasAudio {
                    Button {
                        isMuted.toggle()
                    } label: {
                        Label {
                            isMuted ? Text("サウンドをオン") : Text("サウンドをオフ")
                        } icon: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                    }
                    .accessibilityIdentifier("muteButton")
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: 48, height: 48)

            Spacer()

            Button {
                requestThrow(.keep)
            } label: {
                Label("保持", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .font(.title2.bold())
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("keepButton")

            Button {
                requestThrow(.skip)
            } label: {
                Label("保留", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3.bold())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .tint(.indigo)
            .buttonBorderShape(.circle)
            .accessibilityHint(Text("今回はスキップして、次回また表示します"))
            .accessibilityIdentifier("skipButton")

            Button {
                requestThrow(.trash)
            } label: {
                Label("ゴミ箱に移動", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.title2.bold())
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("trashSwipeButton")

            Spacer()

            Button {
                infoItem = current
            } label: {
                Label("情報", systemImage: "info.circle")
            }
            .disabled(isZoomed)
            .frame(width: 48, height: 48)
            .accessibilityIdentifier("infoButton")
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.glass)
    }

    private func requestThrow(_ decision: Decision) {
        deckThrow = DeckThrow(decision: decision, id: (deckThrow?.id ?? 0) + 1)
    }

    private func finished(_ session: CullSession) -> some View {
        SessionSummaryView(
            total: session.total,
            kept: session.keptCount,
            trashed: session.trashedCount,
            skipped: session.skippedCount,
            trashCount: store.trash.count,
            onReviewTrash: { showTrash = true },
            onDone: { dismiss() }
        )
    }
}

/// Icon + number, tightly spaced (HUD tallies).
struct TallyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension LabelStyle where Self == TallyLabelStyle {
    static var tally: TallyLabelStyle { TallyLabelStyle() }
}
