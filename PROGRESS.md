# Progress

_Last updated: 2026-11-27_

## Done
- **Project setup**: workspace + Swift package created with MobileBuildMCP `scaffold_ios_project`. All code is in `CullPackage/Sources/CullFeature`.
  - `Config/Shared.xcconfig` holds public-safe defaults (`com.example.Cull`, empty `DEVELOPMENT_TEAM`, Swift 6, MainActor default isolation) and includes the gitignored `Config/Local.xcconfig`.
- **Models**:
  - `CullFilter`: album, date range, attributes. Attributes are OR-ed together and AND-ed with the album and date range.
  - `CullQueue`: pure queue with a multi-step undo history, plus per-decision counts for the session.
  - `SwipeRules`: the card's swipe rules, free of SwiftUI so they can be unit tested.
    - The card follows the finger 1:1 from 2 pt.
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
      - The swipe is a `simultaneousGesture`. A plain `.gesture` on the parent waited for the card's own tap / double-tap / pinch to fail, so on a device the card only started moving after the finger had travelled well past the tap tolerance.
      - Pinches are fenced off: `ZoomableContainer` reports pinch start and stop, and a drag that overlaps a pinch never moves the card or decides.
      - The navigation stack's full-width "swipe back from content" gesture (iOS 26+) is disabled while culling. It competed with the right swipe (trash). This uses a UIKit bridge, because SwiftUI has no modifier for it. The edge swipe and the Back button still work.
      - The Live Photo card turns off `PHLivePhotoView`'s own touch handling, because its UIKit recognizer sat outside SwiftUI's gesture system. Touch-and-hold full playback is a SwiftUI long press instead (0.3 s, fails after 10 pt of movement).
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
- **Tooling**: `Scripts/seed_simulator.sh` generates and seeds test media (EXIF photos, a video, a Live Photo pair). `Scripts/make_app_icon.swift <artwork> <appiconset>` builds the three icon variants from square artwork on a flat background. The artwork is kept outside the repo.
- **Performance**: `CullSession.load()` and the album counts now run in `@concurrent` functions, off the main actor.
- **Localization**: String Catalogs (`Cull/Localizable.xcstrings`, `Cull/InfoPlist.xcstrings`). Source language is Japanese, with English translations. Development region is `ja`.
- **Bundle hygiene**: `Config/Local.xcconfig(.example)`, the entitlements file and the test plan are excluded from the app target's synchronized folders, so they never ship inside the app.
- **App icon**: hand-drawn card artwork (cream photo card over a terracotta card).
  - Default: the artwork on its charcoal background, opaque.
  - Dark: the background is flood-filled away to transparency, with the fringe removed, so iOS draws its own dark backdrop.
  - Tinted: grayscale foreground on black.
- **Wordmark**: the setup screen shows "Cull" in Snell Roundhand (built into iOS), the same in every language.
  - Before scrolling: in the `.largeTitle` toolbar slot.
  - Once the large title has scrolled away: a compact version in `.principal`, driven by `onScrollGeometryChange`.
  - Only this screen is affected; there is no global `UINavigationBar` appearance change.
  - `.navigationTitle("Cull")` stays for VoiceOver and the back button.
- **Accessibility**: the Live Photo card hides its inner `PHLivePhotoView` from accessibility (SwiftUI and UIKit side), so the card stays a single "Live Photo" element.
- **Plurals**: English plural variants for "Sorted %lld item(s)." and "%lld kept item(s) will be shown again…".
- **Large-library performance**:
  - `DecisionStore` updates its `keptIDs` / `trash` / `trashedIDs` caches in place after each save instead of re-fetching every row. A failed save rolls back and does a full reload.
  - The setup screen's match count runs in a `@concurrent` function. Stale results are dropped when the filter changes.

## Phase A (2026-11-27): device feedback fixes + features
- **Fix: no video sound on device.** No `AVAudioSession` was configured, so playback used `.soloAmbient` and the Ring/Silent switch muted it. `AudioSessionCoordinator` now uses `.playback` (moviePlayback) while sound is on and `.ambient` + `.mixWithOthers` while muted (so muted autoplay never stops the user's music). Session IPC runs on a serial queue and stale requests are skipped. Also fixed `isMuted` being read from a stale view copy after awaiting the AVAsset: player state lives in `@Observable VideoPlayback`.
- **Fix: cards spinning up the screen on fast consecutive swipes.**
  - Drag state is a `DeckDrag` keyed by the card's `localIdentifier`. A new top card always starts fresh, late callbacks from an old card are ignored, and a `@GestureState` cleans up gestures SwiftUI cancels without `onEnded`.
  - Tilt is clamped (±18°, zero for a degenerate width).
  - The flying card's pose is fixed at throw time (`SwipeRules.throwPose`): it leans its own way and never ends above its resting height.
- **Sort order** (setup screen): newest (default) / oldest / largest. Largest measures sizes in a task group inside the `@concurrent` load, with a launch-long cache and a progress screen.
- **Skip ("not now")**: button between keep and trash, or swipe down (≥ 120 pt or flick). Never persisted; undoable; HUD tally and summary tile. Undo now restores the stored decision from before (matters with "show kept items again").
- **Video seek bar**: elapsed / total and a scrubber on the top video card and trash preview. The deck fences off drags that touch it, like pinches. The card's VoiceOver element moved inside `MediaCardView` so the bar is its own adjustable control (±5 s).
- **Kept screen** (`Features/Kept`): grid of kept items with attribute chips, multi-select → un-keep / send to trash, a full-screen preview. `AssetPreviewView` (`Features/Shared`) is shared with the trash.
- **Reset kept history** sheet: all / by attributes / by album, with a live count.
- Identifier fetches (`fetchAssets(withLocalIdentifiers:options:)`) didn't reliably apply the `mediaSubtypes` bitmask predicate, so kept items matching e.g. Live Photos weren't found. They are now tested in Swift (`CullFilter.matches`). The setup screen's "N to sort" with attributes + kept items used the same path and is fixed too.
- UI tests pin `-sortOrder newest` in the argument domain, so the sort test can't leak into the others.

## Phase B (2026-11-27): analysis and detection
- **All-time space freed**: each confirmed `deleteAssets` from Cull's trash is stored as a `DeletionRecord` (count + bytes, measured just before the delete) in the same SwiftData store. The setup screen shows "これまで合計 X 削減 / N 件を削除しました" once anything has been deleted.
- **Storage screen** (`Features/Storage`, "ストレージを分析" on the setup screen):
  - Library total, a stacked bar and per-type rows (video / screenshot / Live Photo / portrait / panorama / other photos). Each asset is counted in exactly one type (`StorageCategory.classify`), so the rows add up to the total.
  - The 50 biggest files, with thumbnails.
  - Tapping a type, a file or "まとめて整理" starts culling exactly those items, biggest first: new `Route.cullSelection(AssetSelection)`, and `CullSession` takes a fixed identifier list.
  - The scan runs off the main actor (`StorageAnalyzer` → `AssetSizeReader`: parallel, progress, cancel). `StorageModel` lives in the root view, so the last report survives leaving the screen. A library change marks it stale and it is redone.
  - `AssetSizeReader` now also keeps sizes on disk (`Caches/AssetSizes.json`, keyed by modification date), so a relaunch doesn't re-measure.
- **Similar photos** (`Features/Similar`, "似た写真を探す"):
  - Scope: past week / 30 days / 3 months / year / custom range, plus album. There is no whole-library option by design. Match level: near-duplicates only / standard / loose. Only unsorted photos (videos excluded).
  - `SimilarPhotoFinder` (`@concurrent`):
    - Only photos taken within 3 minutes of each other are compared, each against at most 8 earlier ones (`SimilarGrouping.candidatePairs`). Photos with no neighbour in time are never analysed.
    - Each candidate gets a Vision `GenerateImageFeaturePrintRequest` print from a 360 px local thumbnail (no iCloud download), 4 at a time, cached for the launch.
    - Matches under the level's threshold are joined into groups (union-find).
    - Where Vision gives no usable print, a 16×16 colour `ImageSignature` is compared instead. The simulator fails with "Failed to create espresso context", or returns all-zero prints on CPU.
  - Review (`SimilarReviewView`), one group at a time, side by side:
    - The suggested best (favourite > pixels > file size > newest) starts as "残す" and the rest as "ゴミ箱". Tap a photo to flip it; expand opens the full-screen preview.
    - "この内容で整理" records keep/trash and moves to the next group; "スキップ" moves on without recording anything.
- Seed script: adds a near-duplicate pair (`similar_1/2.jpg`, a second apart, 3 days ago). `make_exif_photo.swift` takes an optional seconds-ago argument.
- Only public API in the new code, except the existing `PHAssetResource` `fileSize` KVC read (see Not verified).

## Privacy / efficiency / battery pass (2026-11-27)
- **Audit**:
  - The app has no networking code and Vision runs on device.
  - Network use found:
    - The info-sheet map (MapKit tiles reveal roughly where a photo was taken).
    - PhotoKit iCloud downloads (`isNetworkAccessAllowed = true`, display/EXIF only).
  - No production logging. `assertionFailure` is debug-only, and the delete-error alert shows PhotoKit's message to the user only.
  - The size cache was written without file protection.
  - Size workers used every core. There was no autoreleasepool.
  - Similar-photo analysis was cached in memory only.
  - Scans kept running after their screen closed. Nothing reacted to Low Power Mode or heat.
  - No background handling on the culling screen.
- **Changes**:
  - Map loads only on "地図で表示" (coordinates stay as text). New setting "iCloud から元の写真をダウンロード" (default on) controls every PhotoKit network flag; analysis never downloads.
  - `DiskCache`: generic per-asset on-disk cache. Binary plist, file protection, modification-date keyed, capacity cap, pruned after a full library pass. Used for sizes (`AssetSizes.plist`) and similar-photo analyses (`SimilarAnalyses.plist`, Vision prints are `Codable`), so rescans and relaunches only analyse new or edited items.
  - `ResourceGovernor` / `PaceMonitor`:
    - `.utility` priority, 4 workers max (2 in Low Power Mode, or when `thermalState` is `.fair`).
    - Paused while `.serious`/`.critical`, polling every 2 s, cancellable. The similar-photo scan re-reads the allowed concurrency before each item.
    - The progress UI shows "省電力のため…" / "一時停止中…".
  - Similar thumbnails are 300 px (was 360). Decode + signature, and size measurement, run inside `autoreleasepool` per item.
  - Storage and similar scans cancel on `onDisappear` and when the app leaves the foreground. Storage restarts on return if needed; a similar scan interrupted by the background resumes (cached items are instant).
  - Culling screen: background → stop `PHCachingImageManager` caching, video cards release `AVPlayer` (position restored on return); memory warning → drop the cache and re-warm the next few cards.
- Still uses the non-public `fileSize` KVC key for sizes. It's guarded; when it's missing, sizes show as unknown and nothing is estimated. Decide before App Store submission.

## Polish pass (2026-11-27)
- **Setup screen** reorganised so it's shorter, with the main action clear:
  - "容量を空ける" tiles (容量分析 with the last total, 似た写真, 保持済み with its count) sit right under the wordmark.
  - Then Quick Start.
  - Then one "整理する写真" section: album, date range, attributes as wrapping chips (`FlowLayout`, was 7 rows), and sort order.
  - Then settings.
  - At accessibility text sizes the tiles become full-width rows.
- **Checked in Japanese + dark mode + AX-L Dynamic Type**: setup, culling, storage, info. Fixed:
  - The culling control bar overflowed the screen edges at every size (the glass style pads outside a fixed frame, plus 6 gaps and spacer minimums). Spacing and spacers are tighter now, the side buttons are sized inside their label, and the bar's text size is capped at xxLarge (VoiceOver still reads each label).
  - Storage sizes wrapped as "11.4 / MB", and largest-file labels didn't line up.
  - Icon badges overflowed their 32 pt frames at AX sizes.
- **Seek bar**: a drag that started on the bar's time labels (outside the track) wasn't fenced off and could keep or trash the card. The tighter control bar exposed this in the UI test. Any touch on the bar now blocks swiping.
- **iCloud downloads off**:
  - A photo card whose original is only in iCloud says it's shown at low resolution.
  - A video that can't be played says so.
  - The info sheet explains why camera details and size are missing.
  - All three point to the setting. Detected from PhotoKit's `PHImageResultIsInCloudKey`.
- **Assets deleted elsewhere**: `LibraryReconciler` drops them from kept history, Cull's trash and similar groups, on launch and on every library change. Caches (sizes, analyses) are pruned once per launch at `.utility`.
  - Only with **full access**: with limited access PhotoKit hides unselected assets, so the old trash pruning would have wrongly cleared them. Fixed.
- Cleanup:
  - Removed unused `upNext`, `videoAsset(for:)`, `CullFilter.fetchOptions`, `PhotoLibraryService.fetchAssets(matching:)`.
  - One `ScanProgress` type shared by both scans; `PaceNote` moved to `Features/Shared`.

## Verified
- **Build**: `build_sim` / `build_run_sim` succeed with no warnings (Xcode 27.2, iPhone 18 Pro, iOS 27.2).
- **Tests**: `test_sim` passes 94/94 (75 Swift Testing + 19 XCUITest) after the polish pass, which added reconciler tests: limited access never prunes, deleted IDs leave kept/trash, cache pruning persists. Before that, 90/90 after the privacy/efficiency pass, which added governor, disk-cache and signature round-trip unit tests and a UI test for the opt-in map. Phase B was 83 tests (65 + 18).
  - Phase B added: storage report (one category per asset, totals, ranking, 10k under 1 s), similar grouping (time-window pairs, burst cap, union-find, best pick, periods, pruning), image signature, deletion totals (persist, survive resets) and selection-route unit tests. UI tests: storage → video row starts culling; similar scan finds the seeded pair, marks flip, apply sends one to Cull's trash.
  - Phase A (65/65 then: 49 Swift Testing + 16 XCUITest) added: deck throw/drag isolation, sort, skip, kept-list and Swift-side filter matching unit tests; UI tests for rapid swipes, largest-first, skip, the seek bar, the kept list and reset by attribute. The list below is the pre-Phase-A baseline.
  - 31 Swift Testing unit tests: queue/undo/counts, filter predicates, SwiftData store (including "in-place caches match a fresh reload"), filter presets (month boundaries, matching), swipe rules (axis lock, 1:1 tracking, threshold, throw-back, flick, vertical lock never decides, info).
  - 10 XCUITests:
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
- The iCloud-only notes couldn't be shown in the simulator, which has no iCloud-only assets. They're driven by `PHImageResultIsInCloudKey`; check on a device with iCloud Photos "Optimize Storage" and downloads off.
- **Phase B, needs a device**:
  - Vision feature prints never ran in the simulator, which used the pixel-signature fallback. The same Vision API was checked on macOS: crops and brightness changes of one photo scored 0.04–0.09, unrelated photos 1.0–1.8. The thresholds (0.25 / 0.45 / 0.65) still need tuning on real bursts and look-alike shots.
  - Scan speed on a few thousand photos, and the storage scan on a 10k library, are untimed. Thumbnails are requested synchronously inside the task group (4 at a time).
  - The space-freed total is unit-tested. A confirmed delete wasn't run in UI tests, because it would use up the seed media.
- The storage screen and largest-first both rely on the `fileSize` KVC key, which is not public API. Before App Store submission, weigh it, or fall back to an estimate (e.g. pixel count × type).
- **Phase A, needs a device**:
  - Sound with the Ring/Silent switch on silent, and that muted autoplay leaves other apps' music playing.
  - The fast-swipe spin can't be reproduced in the simulator. The fix removes every path found in the code (shared drag state across cards, cancelled drags leaking, unbounded tilt, upward throw target), and the UI test covers a burst of fast flicks. Confirm on the device it was reported on.
  - Seek-bar feel, and swipe-down-to-skip feel (`SwipeRules.skipDistance` / `skipFlick`).
- Largest-first wasn't timed on a 10k library (the 10k simulator no longer exists). Ordering 10k sizes is unit-tested under 1 s. Size reading is parallel and off-main, but its wall time on a real 10k library is unmeasured.
- The new gesture setup (simultaneous swipe, content back-swipe disabled, Live Photo long press) hasn't yet been tried on a device.
  - In the simulator, the logs showed the back-swipe recognizer is found when culling starts and restored when you leave.
  - Live Photo touch-and-hold playback hasn't been checked.
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
2. In MobileBuildMCP, run `session_show_defaults`, then `test_sim`. The baseline is 94/94 passing. The similar-photos UI test needs the seeded `similar_1/2.jpg` pair: re-run the seed script, or `xcrun simctl addmedia` those two from `TestMedia/`.
3. On a device, check Phase B: similar-photo grouping and thresholds on real bursts, storage totals against Settings › Photos, and the space-freed total after a real delete. Then check Phase A: sound in silent mode, the fast-swipe fix, the seek bar and swipe-down skip (see Not verified). Then check the swipe feel and tune the `SwipeRules` constants if needed. Also check the cards with VoiceOver.
