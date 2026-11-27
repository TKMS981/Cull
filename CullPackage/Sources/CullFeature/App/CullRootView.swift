import Photos
import SwiftData
import SwiftUI

/// App entry view: permission gate → setup → cull / trash.
public struct CullRootView: View {
    @State private var library = PhotoLibraryService()
    @State private var store: DecisionStore
    @State private var path: [Route] = []
    @State private var storage = StorageModel()
    @State private var similar = SimilarScanModel()
    @State private var paceMonitor = PaceMonitor()
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
                            case let .cullSelection(selection):
                                CullView(selection: selection)
                            case .trash:
                                TrashView()
                            case .kept:
                                KeptView()
                            case .storage:
                                StorageView(path: $path)
                            case .similar:
                                SimilarView()
                            }
                        }
                }
                .task(id: library.status) {
                    await reconcile()
                    for await _ in library.changes() {
                        storage.libraryDidChange()
                        await reconcile()
                    }
                }
                .task(id: library.status) {
                    guard LibraryReconciler.canPrune(library.status) else { return }
                    await Task(priority: .utility) { await LibraryReconciler.pruneCaches() }.value
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
        .environment(storage)
        .environment(similar)
        .environment(paceMonitor)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { library.refreshStatus() }
            if phase == .active { paceMonitor.start() } else { paceMonitor.stop() }
        }
    }

    /// Drops records of assets deleted elsewhere (e.g. in Photos): kept history,
    /// Cull's trash and similar-photo groups. Skipped with limited access, where
    /// PhotoKit hides unselected assets rather than reporting them deleted.
    private func reconcile() async {
        guard LibraryReconciler.canPrune(library.status) else { return }
        let decided = store.keptIDs.union(store.trashedIDs)
        let grouped = Set(similar.groups.flatMap(\.assetIDs))
        let ids = decided.union(grouped)
        guard !ids.isEmpty else { return }
        let existing = await LibraryReconciler.existing(among: ids)
        let missing = LibraryReconciler.missing(ids, existing: existing)
        guard !missing.isEmpty else { return }
        store.clear(ids: missing.intersection(decided))
        similar.prune { !missing.contains($0) }
    }
}
