# Cull

SwiftUI app for culling photos, videos and Live Photos one at a time by swiping.

## Targets & toolchain
- iOS 27.0+ only (no `#available` fallbacks below 27). Xcode 27.2, Swift 6.4, Swift 6 language mode.
- Default MainActor isolation (approachable concurrency). Heavy work (image decode, EXIF parsing) goes off the main actor via `@concurrent`.
- SwiftUI first; bridge to UIKit only when SwiftUI can't do the job, and say why.
- No third-party dependencies without asking first.

## Project layout
- `Cull.xcworkspace` (open this) = thin app shell `Cull/` + Swift package `CullPackage/`. All app code lives in `CullPackage/Sources/CullFeature/` (`App/`, `Models/`, `Persistence/`, `Services/`, `Features/{Setup,Cull,Info,Trash}`); `Cull/CullApp.swift` only hosts `CullRootView()`.
- Build settings live in `Config/*.xcconfig`. Never commit a Team ID or personal bundle ID: put them in gitignored `Config/Local.xcconfig` (see `Local.xcconfig.example`).
- Package unit tests: `CullPackage/Tests/CullFeatureTests`. UI tests: `CullUITests/` (target is nonisolated by default via `Tests.xcconfig`).
- UI tests pass `-UITestInMemoryStore` to start with an empty SwiftData store.

## Product rules
- Swipe **left = keep**, swipe **right = move to Cull's temporary trash** (app-local state, not PhotoKit deletion).
- Filter at launch: album, date range, attributes (screenshots, portrait, Live Photo, video, etc.) → `PHFetchOptions` / `PHAssetCollection` smart albums / `mediaSubtypes`.
- While pinch-zoomed (scale > 1), swipe-to-cull **and** swipe-up-for-info are disabled.
- Swipe up → Apple Photos–style info sheet with basic EXIF.
- Undo button reverts the last keep/trash decision.
- Trash screen: multi-select → restore, or bulk-delete via `PHAssetChangeRequest.deleteAssets` (system confirmation dialog is expected).

## PhotoKit notes (not covered by the photokit skill)
- Use `PHCachingImageManager` and pre-cache the next/previous few assets at screen size; request `.opportunistic` delivery for the card, `.highQualityFormat` when zoomed.
- Observe `PHPhotoLibraryChangeObserver` and reconcile the queue/trash when assets change or are deleted outside the app.
- Request `.readWrite` authorization; handle `.limited` access (offer `presentLimitedLibraryPicker`).
- EXIF: `PHAsset` metadata (date, location, pixel size) + `CGImageSourceCopyPropertiesAtIndex` on the image data for camera/lens/exposure.

## Verification
- Build/run/screenshot/UI driving: MobileBuildMCP (project `.mcp.json`, workflows in `.mobilebuildmcp/config.yaml`). Default simulator: iPhone 18 Pro (iOS 27.2).
- Seed the simulator photo library with `xcrun simctl addmedia <udid> <files>` before UI checks.
- Pinch-zoom can't be driven by MobileBuildMCP/AXe (no multi-touch): verify zoom-disables-swipe with XCUITest `pinch(withScale:velocity:)`.
- Unit tests: Swift Testing. UI tests: XCUITest.
