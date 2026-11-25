import Photos

enum DeletionService {
    enum Outcome: Equatable {
        case deleted
        case cancelled
        case failed(String)
    }

    /// Sends assets to the system "Recently Deleted" album. iOS shows its own
    /// confirmation dialog; tapping "Don't Allow" yields `.cancelled`.
    static func delete(ids: [String]) async -> Outcome {
        guard !ids.isEmpty else { return .deleted }
        do {
            try await performDelete(ids: ids)
            return .deleted
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Nonisolated so the change block (run by PhotoKit on its own queue) isn't
    /// MainActor-isolated. Only `Sendable` identifiers cross into it.
    @concurrent
    private static func performDelete(ids: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
