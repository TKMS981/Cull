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
- **Tooling**: `Scripts/seed_simulator.sh` generates and seeds test media (EXIF photos, a video, a Live Photo pair).

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
  - The trash delete shows the iOS confirmation dialog; cancelling keeps the item.
  - Video autoplays, and the mute toggle works.
  - The Live Photo card shows its LIVE badge, and swipe works over it.
  - Undo works from the finished screen.
  - Kept items are skipped after relaunch (the setup count excludes them).

## Not verified / known gaps
- Limited-access flow (`presentLimitedLibraryPicker`) was not exercised; tests ran with full access.
- Confirming a delete was not run on purpose (only cancel). The success path (`store.clear` + change-observer prune) has only been checked by reading the code.
- Live Photo audio and touch-and-hold playback were not checked; the synthetic clip has no audio.
- No performance profiling on a large (10k+) library. `CullSession.load()` enumerates the fetch result on the main actor once per session.
- iPad and landscape are not supported (iPhone portrait only, by design for now).
- UI strings are Japanese literals; no String Catalog or English localization yet.
- Not pushed: the local commits after `chore: initial project setup` are not on GitHub yet.

## Next time, start here
1. `git log --oneline`, then boot the simulator and run `Scripts/seed_simulator.sh` if the library was erased.
2. In MobileBuildMCP, run `session_show_defaults`, then `test_sim`, to confirm a green baseline.
3. Check the limited-access flow: reset privacy (`xcrun simctl privacy <udid> reset photos com.example.Cull`), choose "Limit Access…" at the prompt, then use "アクセスできる写真を管理" (manage accessible photos).
4. Profile `CullSession.load()` with a large seeded library. If it's slow, move the enumeration to a `@concurrent` helper that returns identifiers.
5. Review, then push: `git push origin main`.
