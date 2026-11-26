import Photos
import SwiftUI

/// Swipe-culling screen. Left = keep, right = Cull's trash, up = info.
/// All three swipes are disabled while the card is zoomed (scale > 1).
struct CullView: View {
    let filter: CullFilter
    let includeKept: Bool

    @Environment(PhotoLibraryService.self) private var library
    @Environment(DecisionStore.self) private var store
    @Environment(\.displayScale) private var displayScale

    @State private var session: CullSession?
    @State private var dragOffset: CGSize = .zero
    @State private var isFlying = false
    @State private var isZoomed = false
    @State private var isMuted = true
    @State private var infoItem: CullItem?
    @State private var showTrash = false
    /// Which way the drag would decide if released now (past the threshold), for the haptic tick.
    @State private var armed: Decision?
    @State private var feedback: Feedback?

    /// One haptic event; `id` makes repeated events of the same kind distinct triggers.
    private struct Feedback: Equatable {
        enum Kind { case armed, keep, trash, undo }
        let kind: Kind
        let id: Int
    }

    var body: some View {
        Group {
            if let session, session.phase == .ready {
                content(session)
            } else {
                ProgressView("読み込み中…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
                let newSession = CullSession(filter: filter, includeKept: includeKept, library: library, store: store)
                session = newSession
                await newSession.load()
            }
            for await change in library.changes() {
                session?.apply(change)
            }
        }
        .onDisappear { session?.tearDown() }
        .sensoryFeedback(trigger: feedback) { _, new in
            switch new?.kind {
            case .armed: .impact(weight: .medium, intensity: 0.7)
            case .keep: .impact(weight: .light)
            case .trash: .impact(weight: .heavy, intensity: 0.8)
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
        .disabled(!(session?.canUndo ?? false) || isFlying)
        .accessibilityIdentifier("undoButton")
    }

    private func undo() {
        guard let session, session.canUndo, !isFlying else { return }
        isZoomed = false
        session.undo()
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
        GeometryReader { proxy in
            ZStack {
                // Cards waiting behind; they step forward as the top card is dragged away.
                let behind = session.upcoming(2)
                ForEach(Array(behind.enumerated()).reversed(), id: \.element.id) { index, item in
                    let depth = CGFloat(index + 1) - dragProgress
                    MediaCardView(asset: item.asset, isActive: false, isZoomed: .constant(false), isMuted: true)
                        .overlay { Color.black.opacity(0.18 * depth).allowsHitTesting(false) }
                        .clipShape(.rect(cornerRadius: 24))
                        .scaleEffect(1 - 0.05 * depth)
                        .offset(y: 24 * depth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                MediaCardView(
                    asset: current.asset,
                    isActive: true,
                    isZoomed: $isZoomed,
                    isMuted: isMuted,
                    onToggleMute: { isMuted.toggle() }
                )
                .id(current.id)
                .overlay { decisionTint }
                .overlay { decisionBadge }
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                .offset(x: dragOffset.width, y: min(dragOffset.height, 0) * 0.25)
                .rotationEffect(.degrees(Double(dragOffset.width / proxy.size.width) * 12), anchor: .bottom)
                .gesture(swipeGesture(session, width: proxy.size.width), isEnabled: !isZoomed && !isFlying)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(current.asset.accessibilityKind))
                .accessibilityValue(isZoomed ? "zoomed" : "fit")
                .accessibilityIdentifier("mediaCard")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction(named: "保持") { fly(.keep, session: session, width: proxy.size.width) }
                .accessibilityAction(named: "ゴミ箱に移動") { fly(.trash, session: session, width: proxy.size.width) }
                .accessibilityAction(named: "情報") { infoItem = current }
            }
            .onAppear { updateCacheSize(session, proxy.size) }
            .onChange(of: proxy.size) { _, size in updateCacheSize(session, size) }
        }
    }

    private func updateCacheSize(_ session: CullSession, _ size: CGSize) {
        session.cacheTargetSize = CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    /// 0 at rest, 1 once the drag passes the decision threshold.
    private var dragProgress: CGFloat {
        min(abs(dragOffset.width) / Self.threshold, 1)
    }

    /// A wash of the decision's color over the card that deepens with the drag.
    @ViewBuilder
    private var decisionTint: some View {
        if dragOffset.width != 0 {
            RoundedRectangle(cornerRadius: 24)
                .fill((dragOffset.width < 0 ? Color.green : Color.red).gradient)
                .opacity(0.28 * dragProgress)
                .allowsHitTesting(false)
        }
    }

    /// KEEP (dragging left) / TRASH (dragging right) stamps that fade and settle in with the drag.
    @ViewBuilder
    private var decisionBadge: some View {
        if dragOffset.width < -8 {
            stamp("KEEP", systemImage: "checkmark", color: .green, angle: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        } else if dragOffset.width > 8 {
            stamp("TRASH", systemImage: "trash", color: .red, angle: -12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func stamp(_ title: String, systemImage: String, color: Color, angle: Double) -> some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) }
            .font(.title.weight(.heavy))
            .kerning(1.5)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.85), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color, lineWidth: 4))
            .rotationEffect(.degrees(angle))
            .scaleEffect(0.8 + 0.2 * dragProgress)
            .opacity(dragProgress)
            .padding(28)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func controls(_ session: CullSession, current: CullItem) -> some View {
        HStack(spacing: 20) {
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
                fly(.keep, session: session, width: 400)
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
                fly(.trash, session: session, width: 400)
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
        .disabled(isFlying)
    }

    private func finished(_ session: CullSession) -> some View {
        ContentUnavailableView {
            Label("すべて整理しました", systemImage: "checkmark.seal")
        } description: {
            session.total == 0 ? Text("条件に一致する未整理の写真はありません。") : Text("\(session.total) 件を整理しました。")
        } actions: {
            if !store.trash.isEmpty {
                Button("ゴミ箱を確認（\(store.trash.count)）") { showTrash = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Gesture

    static let threshold: CGFloat = 110

    private func swipeGesture(_ session: CullSession, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                dragOffset = value.translation
                let dx = value.translation.width
                let newArmed: Decision? = dx < -Self.threshold ? .keep : dx > Self.threshold ? .trash : nil
                if newArmed != armed {
                    armed = newArmed
                    if newArmed != nil { emit(.armed) }
                }
            }
            .onEnded { value in
                armed = nil
                let translation = value.translation
                let predicted = value.predictedEndTranslation
                // A pinch that started mid-drag flips isZoomed; never cull in that case.
                guard !isZoomed else { return snapBack() }
                if abs(translation.width) > abs(translation.height) {
                    if translation.width < -Self.threshold || predicted.width < -Self.threshold * 2.5 {
                        fly(.keep, session: session, width: width)
                    } else if translation.width > Self.threshold || predicted.width > Self.threshold * 2.5 {
                        fly(.trash, session: session, width: width)
                    } else {
                        snapBack()
                    }
                } else {
                    if translation.height < -60 || predicted.height < -180 {
                        infoItem = session.current
                    }
                    snapBack()
                }
            }
    }

    private func snapBack() {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { dragOffset = .zero }
    }

    /// Left (keep) flies the card off to the left; right (trash) to the right.
    private func fly(_ decision: Decision, session: CullSession, width: CGFloat) {
        guard !isFlying, session.current != nil else { return }
        isFlying = true
        let direction: CGFloat = decision == .keep ? -1 : 1
        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = CGSize(width: direction * width * 1.5, height: dragOffset.height)
        } completion: {
            session.decide(decision)
            emit(decision == .keep ? .keep : .trash)
            dragOffset = .zero
            isZoomed = false
            isFlying = false
        }
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
