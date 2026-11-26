# Progress

_Last updated: 2026-11-26_

## Done
- **Project setup**: workspace + Swift package created with MobileBuildMCP `scaffold_ios_project`. All code is in `CullPackage/Sources/CullFeature`.
  - `Config/Shared.xcconfig` holds public-safe defaults (`com.example.Cull`, empty `DEVELOPMENT_TEAM`, Swift 6, MainActor default isolation) and includes the gitignored `Config/Local.xcconfig`.
- **Models**:
  - `CullFilter`: album, date range, attributes. Attributes are OR-ed together and AND-ed with the album and date range.
  - `CullQueue`: pure queue with a multi-step undo history, plus per-decision counts for the session.
  - `SwipeRules`: the card's swipe rules, free of SwiftUI so they can be unit tested.
    - The card follows the finger 1:1 from 8 pt.
    - At 12 pt the drag locks to horizontal (keep/trash) or vertical (info) for the rest of the gesture.
    - Keep/trash commits past 38% of the card width, or on a flick whose predicted end is ≥ 90% of the width and whose own travel is ≥ 40 pt. Throwing back toward the centre never commits.
    - Info opens on ≥ 60 pt up, or an upward flick.
  - `FilterPreset`: quick-start presets (screenshots, this month, last month, videos, Live Photos, favorites) that build a `CullFilter` and recognise their own filter, comparing dates by day.
- **Persistence**: `DecisionStore` (SwiftData) keeps kept IDs, which are skipped next time, and Cull's trash. Both persist across launches. Kept history can be reset.
- **Services**:
  - `PhotoLibraryService`: `.readWrite` auth, limited picker, album/asset fetch, `PHPhotoLibraryChangeObserver` fan-out.
  - `ImageLoader`: `PHCachingImageManager`. `.opportunistic` for cards, `.highQualityFormat` when zoomed, plus Live Photo and AVAsset requests.
  - `MetadataReader`: EXIF via `CGImageSource`, parsed in `@concurrent`.
  - `DeletionService`: `PHAssetChangeRequest.deleteAssets`.
  - `AssetSizeReader`: per-asset size summed over all `PHAssetResource`s, read off the main actor. Uses the KVC `fileSize` key, guarded by `responds(to:)`.
- **Screens**:
  - `CullRootView`: permission gate (not determined / denied / full / limited).
  - `FilterSetupView`: Quick Start preset chips (Liquid Glass; the active chip is highlighted, and tapping it again clears the filter), album, dates, attributes, "show kept items again" toggle, reset history, undecided count, limited-access manage button.
  - `CullView`:
    - Swipe left = keep, swipe right = trash, swipe up = info. Keep/trash/info buttons, plus a sound toggle for media with audio.
    - Multi-step undo.
    - Top HUD: progress with this session's keep/trash tallies; undo and trash share one Liquid Glass group.
    - Card stack (`SwipeDeckView`): two cards wait behind the current one and step forward as it is dragged. Pre-caches the next 3 and previous 2 assets.
      - The deck owns the drag state, so finger tracking re-renders only the cards, not the HUD.
      - No animation while dragging; a spring plays only on release.
      - Cards are keyed by asset, so a card keeps its loaded image as it moves from waiting to top to flying away.
      - A thrown card leaves as a non-interactive layer, and the decision is recorded on release. The next card can be grabbed at once, with no lockout while the animation plays.
      - Undo glides a card that is still flying back to the centre.
    - While dragging, the card tilts, a KEEP / TRASH stamp fades and scales in, and a colour wash deepens.
    - Haptics: a tick when the drag passes the threshold, distinct impacts for keep and trash, a soft one for undo, and success on the summary screen.
    - Session summary when the queue empties: this run's keep and trash tiles, "Review Trash (N)" and "Change Filters".
    - Reconciles with outside library changes.
  - Zoom: pinch, pan, double-tap. While zoomed (scale > 1), left/right **and** up swipes are disabled.
  - Video: muted autoplay with looping; tap the card or the speaker button to toggle sound. Uses `AVPlayerLayer` because `VideoPlayer`'s controls swallow gestures.
  - Live Photo: `PHLivePhotoView` with a hint playback; touch-and-hold plays it fully.
  - `AssetInfoSheet`: date, file name, type, camera, lens, exposure, resolution/MP, duration, file size, format, map.
  - `TrashView`:
    - Grid, multi-select (from the Select button), select all.
    - Restore (re-queues into the active session); delete (system confirmation → Recently Deleted).
    - "About N MB can be freed" header, for the whole trash or the selection.
    - Tapping a cell opens a full-screen preview (zoom transition) that reuses the culling card, with restore and delete.
- **Tooling**: `Scripts/seed_simulator.sh` generates and seeds test media (EXIF photos, a video, a Live Photo pair). `Scripts/make_app_icon.swift` regenerates the app icon.
- **Performance**: `CullSession.load()` and the album counts now run in `@concurrent` functions, off the main actor.
- **Localization**: String Catalogs (`Cull/Localizable.xcstrings`, `Cull/InfoPlist.xcstrings`). Source language is Japanese, with English translations. Development region is `ja`.
- **Bundle hygiene**: `Config/Local.xcconfig(.example)`, the entitlements file and the test plan are excluded from the app target's synchronized folders, so they never ship inside the app.
- **App icon**: light, dark and tinted variants.
- **Accessibility**: the Live Photo card hides its inner `PHLivePhotoView` from accessibility (SwiftUI and UIKit side), so the card stays a single "Live Photo" element.
- **Plurals**: English plural variants for "Sorted %lld item(s)." and "%lld kept item(s) will be shown again…".
- **Large-library performance**:
  - `DecisionStore` updates its `keptIDs` / `trash` / `trashedIDs` caches in place after each save instead of re-fetching every row. A failed save rolls back and does a full reload.
  - The setup screen's match count runs in a `@concurrent` function. Stale results are dropped when the filter changes.

## Verified
- **Build**: `build_sim` / `build_run_sim` succeed with no warnings (Xcode 27.2, iPhone 18 Pro, iOS 27.2).
- **Tests**: `test_sim` passes 43/43.
  - 31 Swift Testing unit tests: queue/undo/counts, filter predicates, SwiftData store (including "in-place caches match a fresh reload"), filter presets (month boundaries, matching), swipe rules (axis lock, 1:1 tracking, threshold, throw-back, flick, vertical lock never decides, info).
  - 12 XCUITests:
    - Pinch zoom disables left/right/up swipes; double-tap restores swiping.
    - Trash → restore re-queues the item.
    - Swipe up opens info.
    - Keep/trash buttons with two undos.
    - The Live Photo card is announced as "Live Photo".
    - English plural forms (one / other).
    - Session summary tallies → Review Trash → Change Filters.
    - Trash size header plus preview → restore.
    - Quick Start presets apply, highlight and clear.
    - Short sideways drags, mostly-vertical drags and downward drags don't decide or open info.
- **10k-photo profiling** (Release build, separate simulator with 10,006 photos, `ContinuousClock` timing that was removed afterwards):

  | Operation | Before | After |
  |---|---|---|
  | Keep/trash per swipe (main), ~9,000 decisions stored | 83–86 ms | 1.7–4 ms |
  | Undo (main) | same as above | 1.6 ms |
  | Setup count with an album selected (main) | 125 ms | ~0 (143 ms off-main) |
  | `CullSession.load()` (off-main) | 147–174 ms | unchanged |
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
- The in-motion look of the stamps, tint and card stack, the haptics, and the feel of the new swipe tracking haven't been checked by hand. AXe can't hold a drag mid-gesture, and the simulator has no haptics.
  - Try them on a device. The tuning values are constants in `SwipeRules`.
- The trash size uses `PHAssetResource`'s undocumented `fileSize` key. It is guarded, so a missing key just leaves the size out, but it isn't public API.
- In selection mode, XCUITest reports trash cells as not hittable, so the test taps their centre directly. A real tap works.
- Limited picker: selecting items inside it couldn't be automated, because the picker runs out of process and AXe can't see it. Whether the count refreshes after the selection changes has only been checked by reading the code: the change observer fires and the setup screen recounts.
- Live Photo audio and touch-and-hold playback were not checked; the synthetic clip has no audio.
- VoiceOver itself hasn't been run. On iOS 27, XCUITest and AXe list `.accessibilityHidden` and `children: .ignore` descendants: a hidden probe `Text` on the setup screen showed up too. So they can't prove what VoiceOver skips. Check the cards with VoiceOver on a device.
- iPhone portrait only.

## Next time, start here
1. `git pull`, then boot the simulator and run `Scripts/seed_simulator.sh` if the library was erased.
2. In MobileBuildMCP, run `session_show_defaults`, then `test_sim`. The baseline is 43/43 passing.
3. On a device, check the swipe feel and tune the `SwipeRules` constants if needed. Also check the cards with VoiceOver.
