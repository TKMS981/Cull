# Cull

An iOS 27 SwiftUI app for culling your photo library one item at a time.

- **Swipe left**: keep (remembered, skipped next time)
- **Swipe right**: move to Cull's own trash (nothing is deleted yet)
- **Swipe up**: Photos-style info (date, camera, exposure, resolution, size, location)
- **Undo**: step back through decisions
- **Pinch / double-tap**: zoom. While zoomed, swipes pan the image instead of culling.
- **Trash**: multi-select, then restore or delete (iOS asks for confirmation; items go to Recently Deleted)

Filters at launch: album, date range, attributes (screenshots, portrait, Live Photos, video, favorites, panorama, HDR; OR-combined).

## Build

Open `Cull.xcworkspace` in Xcode 27.2+. Simulator builds need no signing.
For a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Team ID and bundle ID (that file is gitignored).

## Layout

```
Cull/                 App shell (entry point only)
CullPackage/          All features (Swift package)
  Sources/CullFeature/
    App/              CullRootView (permission gate + navigation)
    Models/           CullFilter, CullQueue (pure, unit-tested)
    Persistence/      DecisionStore (SwiftData)
    Services/         PhotoLibraryService, ImageLoader, MetadataReader, DeletionService
    Features/         Setup, Cull, Info, Trash
  Tests/              Swift Testing unit tests
CullUITests/          XCUITest (incl. pinch-zoom disables swipe)
Config/               xcconfig files
```

## Tests

Seed the simulator first, then run the `Cull` scheme's tests:

```sh
xcrun simctl addmedia <udid> <some photos and a video>
xcrun simctl privacy <udid> grant photos com.example.Cull
```

No third-party dependencies.
