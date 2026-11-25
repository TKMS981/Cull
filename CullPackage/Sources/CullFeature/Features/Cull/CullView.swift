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
            ToolbarItem(placement: .topBarTrailing) { trashButton }
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
        .sensoryFeedback(.impact(weight: .light), trigger: session?.decidedCount)
    }

    // MARK: Header

    @ViewBuilder
    private var progressHeader: some View {
        if let session, session.total > 0 {
            VStack(spacing: 4) {
                Text("残り \(session.remaining) / \(session.total)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: Double(session.decidedCount), total: Double(max(session.total, 1)))
                    .frame(width: 140)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("残り \(session.remaining) 件、全 \(session.total) 件")
            .accessibilityValue("\(session.remaining)")
            .accessibilityIdentifier("progress")
        }
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
        .accessibilityValue("\(store.trash.count) 件")
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
                if let next = session.upNext {
                    MediaCardView(asset: next.asset, isActive: false, isZoomed: .constant(false), isMuted: true)
                        .scaleEffect(0.94)
                        .opacity(nextCardOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .id(next.id)
                }

                MediaCardView(
                    asset: current.asset,
                    isActive: true,
                    isZoomed: $isZoomed,
                    isMuted: isMuted,
                    onToggleMute: { isMuted.toggle() }
                )
                .id(current.id)
                .overlay { decisionBadge }
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

    private var nextCardOpacity: Double {
        min(0.4 + abs(dragOffset.width) / 300, 1)
    }

    @ViewBuilder
    private var decisionBadge: some View {
        let progress = min(abs(dragOffset.width) / Self.threshold, 1)
        if dragOffset.width < -8 {
            stamp("保持", systemImage: "checkmark.circle.fill", color: .green)
                .opacity(progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        } else if dragOffset.width > 8 {
            stamp("ゴミ箱", systemImage: "trash.fill", color: .red)
                .opacity(progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func stamp(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color.gradient, in: .capsule)
            .padding(24)
    }

    private func controls(_ session: CullSession, current: CullItem) -> some View {
        HStack(spacing: 20) {
            Button {
                isZoomed = false
                session.undo()
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo || isFlying)
            .accessibilityIdentifier("undoButton")

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

            HStack(spacing: 12) {
                if current.asset.hasAudio {
                    Button {
                        isMuted.toggle()
                    } label: {
                        Label(isMuted ? "サウンドをオン" : "サウンドをオフ", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityIdentifier("muteButton")
                }
                Button {
                    infoItem = current
                } label: {
                    Label("情報", systemImage: "info.circle")
                }
                .disabled(isZoomed)
                .accessibilityIdentifier("infoButton")
            }
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
            Text(session.total == 0 ? "条件に一致する未整理の写真はありません。" : "\(session.total) 件を整理しました。")
        } actions: {
            if session.canUndo {
                Button("元に戻す") { session.undo() }
            }
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
            }
            .onEnded { value in
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
            dragOffset = .zero
            isZoomed = false
            isFlying = false
        }
    }
}
