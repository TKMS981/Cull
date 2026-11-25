import MapKit
import Photos
import SwiftUI

/// Photos-style info panel: date, camera, exposure, resolution, size, location.
struct AssetInfoSheet: View {
    let asset: PHAsset

    @State private var info: AssetInfo?

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    header(info)
                    cameraSection(info)
                    fileSection(info)
                    locationSection(info)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("情報")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("infoSheet")
        }
        .task(id: asset.localIdentifier) {
            info = MetadataReader.basicInfo(for: asset)
            info = await MetadataReader.info(for: asset)
        }
    }

    private func header(_ info: AssetInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let date = info.creationDate {
                    Text(date, format: .dateTime.weekday(.wide).year().month().day())
                        .font(.headline)
                    Text(date, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                } else {
                    Text("日付なし").font(.headline)
                }
                if let fileName = info.fileName {
                    Text(fileName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("種類") {
                Label(kindTitle(info.kind), systemImage: kindSymbol(info.kind))
            }
            if info.isFavorite {
                LabeledContent("お気に入り") { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            }
        }
    }

    @ViewBuilder
    private func cameraSection(_ info: AssetInfo) -> some View {
        if info.cameraName != nil || info.lensModel != nil || info.fNumber != nil {
            Section("カメラ") {
                if let camera = info.cameraName {
                    LabeledContent("機種", value: camera)
                }
                if let lens = info.lensModel {
                    LabeledContent("レンズ", value: lens)
                }
                let exposure = exposureSummary(info)
                if !exposure.isEmpty {
                    LabeledContent("露出", value: exposure)
                }
            }
        }
    }

    private func fileSection(_ info: AssetInfo) -> some View {
        Section("ファイル") {
            LabeledContent("解像度") {
                let megapixels = info.kind == .video ? "" : String(format: "  (%.1f MP)", info.megapixels)
                Text(verbatim: "\(info.pixelWidth) × \(info.pixelHeight)\(megapixels)")
            }
            if let duration = info.duration {
                LabeledContent("長さ") {
                    Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
                }
            }
            if let size = info.fileSize {
                LabeledContent("ファイルサイズ") {
                    Text(size, format: .byteCount(style: .file))
                }
            }
            if let uti = info.uniformType, let type = UTType(uti) {
                LabeledContent("フォーマット", value: type.preferredFilenameExtension?.uppercased() ?? uti)
            }
        }
    }

    @ViewBuilder
    private func locationSection(_ info: AssetInfo) -> some View {
        if let coordinate = info.coordinate {
            Section("撮影地") {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                    Marker("", coordinate: coordinate)
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets())
                .allowsHitTesting(false)
                Text(verbatim: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exposureSummary(_ info: AssetInfo) -> String {
        var parts: [String] = []
        if let focal = info.focalLength35mm { parts.append("\(focal) mm") }
        if let f = info.fNumber { parts.append(String(format: "ƒ%.1f", f)) }
        if let t = info.exposureTime {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = info.iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ·  ")
    }

    private func kindTitle(_ kind: AssetInfo.Kind) -> LocalizedStringKey {
        switch kind {
        case .photo: "写真"
        case .livePhoto: "Live Photo"
        case .video: "ビデオ"
        case .screenshot: "スクリーンショット"
        case .portrait: "ポートレート"
        case .panorama: "パノラマ"
        }
    }

    private func kindSymbol(_ kind: AssetInfo.Kind) -> String {
        switch kind {
        case .photo: "photo"
        case .livePhoto: "livephoto"
        case .video: "video"
        case .screenshot: "camera.viewfinder"
        case .portrait: "cube"
        case .panorama: "pano"
        }
    }
}
