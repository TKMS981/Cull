import SwiftUI

/// Shown when a session's queue is empty: what this run decided, and where to go next.
struct SessionSummaryView: View {
    /// Items the session started with (plus any re-queued).
    let total: Int
    let kept: Int
    let trashed: Int
    /// Everything in Cull's trash, not just this session's.
    let trashCount: Int
    var onReviewTrash: () -> Void
    var onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        if total == 0 {
            ContentUnavailableView {
                Label("整理する写真はありません", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("条件に一致する未整理の写真はありません。")
            } actions: {
                Button("条件を変えて続ける", action: onDone)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("summaryDoneButton")
            }
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, value: appeared)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("すべて整理しました")
                    .font(.title.bold())
                Text("\(total) 件を整理しました。")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    tile("保持", systemImage: "checkmark", count: kept, color: .green)
                        .accessibilityIdentifier("summaryKept")
                    tile("ゴミ箱へ", systemImage: "trash", count: trashed, color: .red)
                        .accessibilityIdentifier("summaryTrashed")
                }
            }

            VStack(spacing: 12) {
                if trashCount > 0 {
                    Button(action: onReviewTrash) {
                        Label("ゴミ箱を確認（\(trashCount)）", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .accessibilityIdentifier("reviewTrashButton")
                }
                Button(action: onDone) {
                    Text("条件を変えて続ける")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("summaryDoneButton")
            }
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionSummary")
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private func tile(_ title: LocalizedStringKey, systemImage: String, count: Int, color: Color) -> some View {
        VStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(count, format: .number)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassEffect(.regular.tint(color.opacity(0.12)), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}
