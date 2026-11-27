import Photos
import SwiftData
import SwiftUI

/// App entry view: permission gate → setup → cull / trash.
public struct CullRootView: View {
    @State private var library = PhotoLibraryService()
    @State private var store: DecisionStore
    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    /// Launch argument used by UI tests to start from a clean, throwaway store.
    static let inMemoryStoreArgument = "-UITestInMemoryStore"

    public init() {
        let inMemory = ProcessInfo.processInfo.arguments.contains(Self.inMemoryStoreArgument)
        let container: ModelContainer
        do {
            container = try DecisionStore.makeContainer(inMemory: inMemory)
        } catch {
            // Corrupt on-disk store: keep the app usable this session instead of crashing.
            do {
                container = try DecisionStore.makeContainer(inMemory: true)
            } catch {
                fatalError("Unable to create even an in-memory SwiftData store: \(error)")
            }
        }
        _store = State(initialValue: DecisionStore(container: container))
    }

    public var body: some View {
        Group {
            switch library.status {
            case .authorized, .limited:
                NavigationStack(path: $path) {
                    FilterSetupView(path: $path)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case let .cull(filter, sort, includeKept):
                                CullView(filter: filter, sort: sort, includeKept: includeKept)
                            case .trash:
                                TrashView()
                            case .kept:
                                KeptView()
                            }
                        }
                }
                .task(id: library.status) {
                    pruneTrash()
                    for await _ in library.changes() { pruneTrash() }
                }
            case .notDetermined:
                ContentUnavailableView {
                    Label("写真へのアクセス", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Cull はライブラリの写真とビデオを1枚ずつ表示して整理します。削除は確認のうえ「最近削除した項目」に移動されます。")
                } actions: {
                    Button("アクセスを許可") {
                        Task { await library.requestAuthorization() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("requestAccessButton")
                }
            default:
                ContentUnavailableView {
                    Label("写真へのアクセスがありません", systemImage: "lock")
                } description: {
                    Text("設定アプリで Cull に写真へのアクセスを許可してください。")
                } actions: {
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .environment(library)
        .environment(store)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshStatus() }
        }
    }

    /// Drops trash entries whose assets were deleted elsewhere (or after our own delete).
    private func pruneTrash() {
        let ids = store.trash.map(\.id)
        guard !ids.isEmpty else { return }
        let existing = library.assets(withIDs: ids)
        let missing = ids.filter { existing[$0] == nil }
        if !missing.isEmpty { store.clear(ids: missing) }
    }
}
