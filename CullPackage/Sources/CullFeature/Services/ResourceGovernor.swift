import Foundation
import Observation

/// How hard background analysis (storage scan, similar photos, size measuring) may
/// work right now, from Low Power Mode and the thermal state.
nonisolated enum WorkPace: Equatable, Sendable {
    case normal
    /// Low Power Mode or a warm device: fewer workers.
    case reduced
    /// Hot device: stop until it cools down.
    case paused
}

nonisolated enum ResourceGovernor {
    /// The most work items run at once, whatever the device (keeps memory spikes down).
    static let maxConcurrency = 4

    static func pace(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> WorkPace {
        switch thermal {
        case .serious, .critical: .paused
        case .fair: .reduced
        default: lowPower ? .reduced : .normal
        }
    }

    static var currentPace: WorkPace {
        let info = ProcessInfo.processInfo
        return pace(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }

    static func concurrency(for pace: WorkPace, limit: Int = maxConcurrency) -> Int {
        switch pace {
        case .normal: max(1, limit)
        case .reduced: max(1, limit / 2)
        case .paused: 0
        }
    }

    /// Waits while the device is too hot. Returns `false` if the task was cancelled.
    static func waitUntilAllowed(pollEvery interval: Duration = .seconds(2)) async -> Bool {
        while currentPace == .paused {
            guard (try? await Task.sleep(for: interval)) != nil else { return false }
        }
        return !Task.isCancelled
    }
}

/// The current pace for the UI ("paused while the device cools down"), updated from
/// the system's power and thermal notifications.
@Observable
final class PaceMonitor {
    private(set) var pace: WorkPace = ResourceGovernor.currentPace

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    func start() {
        guard tasks.isEmpty else { return }
        pace = ResourceGovernor.currentPace
        tasks = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange].map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.pace = ResourceGovernor.currentPace
                }
            }
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
