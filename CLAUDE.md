# Cull

SwiftUI app for culling photos, videos and Live Photos one at a time by swiping.

## Targets & toolchain
- iOS 27.0+ only (no `#available` fallbacks below 27). Xcode 27.2, Swift 6.4, Swift 6 language mode.
- Default MainActor isolation (approachable concurrency). Heavy work (image decode, EXIF parsing) goes off the main actor via `@concurrent`.
- SwiftUI first; bridge to UIKit only when SwiftUI can't do the job, and say why.
- No third-party dependencies without asking first.

## Project layout
- `Cull.xcworkspace` (open this) = thin app shell `Cull/` + Swift package `CullPackage/`. All app code lives in `CullPackage/Sources/CullFeature/` (`App/`, `Models/`, `Persistence/`, `Services/`, `Features/{Setup,Cull,Info,Trash,Kept,Storage,Similar,Shared}`); `Cull/CullApp.swift` only hosts `CullRootView()`.
- Build settings live in `Config/*.xcconfig`. Never commit a Team ID or personal bundle ID: put them in gitignored `Config/Local.xcconfig` (see `Local.xcconfig.example`).
- Package unit tests: `CullPackage/Tests/CullFeatureTests`. UI tests: `CullUITests/` (target is nonisolated by default via `Tests.xcconfig`).
- UI tests pass `-UITestInMemoryStore` to start with an empty SwiftData store.

## Product rules
- Swipe **left = keep**, swipe **right = move to Cull's temporary trash** (app-local state, not PhotoKit deletion), swipe **down = skip** ("not now": this session only, never persisted).
- Filter at launch: album, date range, attributes (screenshots, portrait, Live Photo, video, etc.) → `PHFetchOptions` / `PHAssetCollection` smart albums / `mediaSubtypes`. Sort: newest / oldest / largest (sizes measured off-main).
- While pinch-zoomed (scale > 1), swipe-to-cull, swipe-down-to-skip **and** swipe-up-for-info are disabled. A drag on the video seek bar never culls either.
- Swipe up → Apple Photos–style info sheet with basic EXIF.
- Undo button reverts the last keep/trash/skip decision (restoring what was stored before).
- Trash screen: multi-select → restore, or bulk-delete via `PHAssetChangeRequest.deleteAssets` (system confirmation dialog is expected).
- Kept screen: grid of kept items (attribute filter), multi-select → un-keep or send to trash. Kept history resets all, by attribute, or by album.
- Trash deletions add to an all-time "space freed" total (`DeletionRecord`) shown on the setup screen.
- Storage screen: library total, per-type breakdown (each asset in one `StorageCategory`), top 50 files; tapping any of them culls exactly those items biggest first (`Route.cullSelection`). Sizes are measured off-main and cached on disk.
- Similar photos: scoped to a period/album (never the whole library), photos close in time compared with Vision feature prints (pixel-signature fallback where Vision can't run, e.g. the simulator); review one group at a time, apply = keep/trash.
- Audio: muted autoplay uses `.ambient` + mixWithOthers; sound on switches to `.playback` (heard in silent mode). See `AudioSessionCoordinator`.

## Privacy, memory & battery rules
- No networking code in the app. The only network use is the system's own:
  - PhotoKit fetching originals from the user's iCloud Photos for display, playback and EXIF. This follows the "iCloud から元の写真をダウンロード" setting (`ImageLoader.allowsICloudDownload`). Analysis (sizes, similar photos) never downloads.
  - The info-sheet map, which loads only after the user taps "地図で表示".
- Never log identifiers, file names, paths, locations or EXIF. There is no logging in production code; if some is ever needed, use `Logger` with `privacy: .private`. `assertionFailure` messages are debug-only.
- Per-asset caches (`DiskCache`) hold identifiers and derived numbers only (sizes, feature prints, 16×16 signatures). They live in Caches, are written with `.completeFileProtectionUntilFirstUserAuthentication`, are keyed by modification date (differential), and are pruned to existing assets after a full pass.
- Bulk work:
  - Runs `@concurrent` at `.utility` priority.
  - At most `ResourceGovernor.maxConcurrency` (4) at a time, half in Low Power Mode, paused while `thermalState` is `.serious` or above. The UI says so (`PaceNote`).
  - Downsample before decoding (similar: 300 px thumbnails, never full resolution), and wrap per-item ObjC/PhotoKit work in `autoreleasepool`.
- Scans are cancelled when their screen disappears or the app leaves the foreground. Results resume from the caches.
- In the background, the culling screen drops `PHCachingImageManager` caching and video cards release their `AVPlayer` (position kept). A memory warning drops the cache too.

## PhotoKit notes (not covered by the photokit skill)
- Use `PHCachingImageManager` and pre-cache the next/previous few assets at screen size; request `.opportunistic` delivery for the card, `.highQualityFormat` when zoomed.
- Observe `PHPhotoLibraryChangeObserver` and reconcile the queue/trash when assets change or are deleted outside the app.
- Request `.readWrite` authorization; handle `.limited` access (offer `presentLimitedLibraryPicker`).
- EXIF: `PHAsset` metadata (date, location, pixel size) + `CGImageSourceCopyPropertiesAtIndex` on the image data for camera/lens/exposure.

## Verification
- Build/run/screenshot/UI driving: MobileBuildMCP (project `.mcp.json`, workflows in `.mobilebuildmcp/config.yaml`). Default simulator: iPhone 18 Pro (iOS 27.2).
- Seed the simulator photo library with `Scripts/seed_simulator.sh [udid]` (wraps `xcrun simctl addmedia`; creates photos with EXIF, a video and a Live Photo pair) before UI checks.
- Pinch-zoom can't be driven by MobileBuildMCP/AXe (no multi-touch): verify zoom-disables-swipe with XCUITest `pinch(withScale:velocity:)`.
- Unit tests: Swift Testing. UI tests: XCUITest.
