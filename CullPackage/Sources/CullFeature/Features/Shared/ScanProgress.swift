import SwiftUI

/// Progress of a long scan (storage, similar photos): items done out of total.
struct ScanProgress: Equatable {
    var done: Int
    var total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Tells the user why a scan runs slower or has stopped.
struct PaceNote: View {
    let pace: WorkPace

    var body: some View {
        switch pace {
        case .normal:
            EmptyView()
        case .reduced:
            Label("省電力のため、ゆっくり解析しています", systemImage: "leaf")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("paceReduced")
        case .paused:
            Label("端末が熱くなっているため一時停止中です。冷えると再開します", systemImage: "thermometer.high")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("pacePaused")
        }
    }
}
