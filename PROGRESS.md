# Progress

_Last updated: 2026-11-26_

## Done
- **Project setup**: workspace + Swift package created with MobileBuildMCP `scaffold_ios_project`. All code is in `CullPackage/Sources/CullFeature`.
  - `Config/Shared.xcconfig` holds public-safe defaults (`com.example.Cull`, empty `DEVELOPMENT_TEAM`, Swift 6, MainActor default isolation) and includes the gitignored `Config/Local.xcconfig`.
- **Models**:
  - `CullFilter`: album, date range, attributes. Attributes are OR-ed together and AND-ed with the album and date range.
  - `CullQueue`: pure queue with a multi-step undo history.
- **Persistence**: `DecisionStore` (SwiftData) keeps kept IDs, which are skipped next time, and Cull's trash. Both persist across launches. Kept history can be reset.
- **Services**:
  - `PhotoLibraryService`: `.readWrite` auth, limited picker, album/asset fetch, `PHPhotoLibraryChangeObserver` fan-out.
  - `ImageLoader`: `PHCachingImageManager`. `.opportunistic` for cards, `.highQualityFormat` when zoomed, plus Live Photo and AVAsset requests.
  - `MetadataReader`: EXIF via `CGImageSource`, parsed in `@concurrent`.
  - `DeletionService`: `PHAssetChangeRequest.deleteAssets`.
- **Screens**:
  - `CullRootView`: permission gate (not determined / denied / full / limited).
  - `FilterSetupView`: album, dates, attributes, "show kept items again" toggle, reset history, undecided count, limited-access manage button.
  - `CullView`:
    - Swipe left = keep, swipe right = trash, swipe up = info. Keep/trash/undo/info buttons as well.
    - Multi-step undo.
    - Progress header and trash badge.
    - Next card shown behind the current one; pre-caches the next 3 and previous 2 assets.
    - Reconciles with outside library changes.
  - Zoom: pinch, pan, double-tap. While zoomed (scale > 1), left/right **and** up swipes are disabled.
  - Video: muted autoplay with looping; tap the card or the speaker button to toggle sound. Uses `AVPlayerLayer` because `VideoPlayer`'s controls swallow gestures.
  - Live Photo: `PHLivePhotoView` with a hint playback; touch-and-hold plays it fully.
  - `AssetInfoSheet`: date, file name, type, camera, lens, exposure, resolution/MP, duration, file size, format, map.
  - `TrashView`: grid, multi-select, select all, restore (re-queues into the active session), delete (system confirmation → Recently Deleted).
- **Tooling**: `Scripts/seed_simulator.sh` generates and seeds test media (EXIF photos, a video, a Live Photo pair). `Scripts/make_app_icon.swift` regenerates the app icon.
- **Performance**: `CullSession.load()` and the album counts now run in `@concurrent` functions, off the main actor.
- **Localization**: String Catalogs (`Cull/Localizable.xcstrings`, `Cull/InfoPlist.xcstrings`). Source language is Japanese, with English translations. Development region is `ja`.
- **Bundle hygiene**: `Config/Local.xcconfig(.example)`, the entitlements file and the test plan are excluded from the app target's synchronized folders, so they never ship inside the app.
- **App icon**: light, dark and tinted variants.

## Verified
- **Build**: `build_sim` / `build_run_sim` succeed with no warnings (Xcode 27.2, iPhone 18 Pro, iOS 27.2).
- **Tests**: `test_sim` passes 18/18.
  - 14 Swift Testing unit tests: queue/undo, filter predicates, SwiftData store.
  - 4 XCUITests:
    - Pinch zoom disables left/right/up swipes; double-tap restores swiping.
    - Trash → restore re-queues the item.
    - Swipe up opens info.
    - Keep/trash buttons with two undos.
- **Simulator, by hand with MobileBuildMCP**:
  - Swipes and the trash badge work.
  - The info sheet shows EXIF.
  - Video autoplays, and the mute toggle works.
  - The Live Photo card shows its LIVE badge, and swipe works over it.
  - Undo works from the finished screen.
  - Kept items are skipped after relaunch.
  - Trash delete, cancelled: the item stays in the trash.
  - Trash delete, **allowed**: the asset is removed from the library and Cull's trash empties.
  - Permission gate: the "not determined" screen appears, then the system prompt with the usage description.
  - **Limited access**: the banner and "Manage Accessible Photos" appear, and the system limited picker opens.
  - English UI on an English-locale simulator.
  - Dark mode.

## Not verified / known gaps
- Limited picker: selecting items inside it couldn't be automated, because the picker runs out of process and AXe can't see it. Whether the count refreshes after the selection changes has only been checked by reading the code: the change observer fires and the setup screen recounts.
- Live Photo audio and touch-and-hold playback were not checked; the synthetic clip has no audio.
- No measured profiling on a 10k+ library. The heavy work is now off the main actor, but it hasn't been timed.
- With `.accessibilityElement(children: .ignore)` on the card, the Live Photo's UIKit subview and LIVE label still appear as separate elements in AXe snapshots. Check with VoiceOver.
- Plural forms in English use "items" for every count; there are no plural variants in the catalog yet.
- iPhone portrait only.

## Next time, start here
1. `git pull`, then boot the simulator and run `Scripts/seed_simulator.sh` if the library was erased.
2. In MobileBuildMCP, run `session_show_defaults`, then `test_sim`. The baseline is 18/18 passing.
3. Check VoiceOver on the Live Photo card; hide the inner `PHLivePhotoView` from accessibility if needed.
4. Add plural variants to `Localizable.xcstrings`, e.g. "Sorted 1 item" vs "Sorted %lld items".
5. Seed a large library (e.g. a loop over `simctl addmedia`) and profile `CullSession.load()` and the setup count in Instruments.
