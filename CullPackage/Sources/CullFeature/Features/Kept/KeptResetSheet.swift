import SwiftUI

/// Resets kept history: everything, or only kept items matching attributes or an album.
/// Un-kept items are culled again next time; Cull's trash is untouched.
struct KeptResetSheet: View {
    @Environment(DecisionStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case all, attributes, album
        var id: String { rawValue }
    }

    @State private var scope: Scope = .all
    @State private var attributes: Set<MediaAttribute> = []
    @State private var albumID: String?
    /// Kept IDs the current scope would reset; `nil` while counting.
    @State private var matching: Set<String>?

    /// The scope as a filter, or `nil` for "all kept items".
    private var filter: CullFilter? {
        switch scope {
        case .all: nil
        case .attributes: attributes.isEmpty ? nil : CullFilter(attributes: attributes)
        case .album: albumID.map { CullFilter(albumID: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("対象", selection: $scope) {
                        Text("すべて").tag(Scope.all)
                        Text("属性").tag(Scope.attributes)
                        Text("アルバム").tag(Scope.album)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("resetScopePicker")
                }
                switch scope {
                case .all:
                    EmptyView()
                case .attributes:
                    attributeSection
                case .album:
                    albumSection
                }
            }
            // Always in reach, however long the attribute / album list gets.
            .safeAreaInset(edge: .bottom) { confirmBar }
            .navigationTitle("整理済み履歴をリセット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
            }
            .task { if library.albums.isEmpty { await library.loadAlbums() } }
            .task(id: CountKey(scope: scope, attributes: attributes, albumID: albumID, kept: store.keptIDs.count)) {
                await count()
            }
        }
        .presentationDetents([.large])
    }

    private var confirmBar: some View {
        VStack(spacing: 8) {
            Text("「保持」にした \(matching?.count ?? 0) 件が再び整理対象になります。ゴミ箱の内容は変わりません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(role: .destructive) {
                if scope == .all {
                    store.resetKept()   // one batch delete, however many are kept
                } else if let matching {
                    store.clear(ids: matching)
                }
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if matching == nil { ProgressView() }
                    Text("\(matching?.count ?? 0) 件の保持を解除")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(matching?.isEmpty ?? true)
            .accessibilityIdentifier("confirmResetKeptButton")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private struct CountKey: Hashable {
        let scope: Scope
        let attributes: Set<MediaAttribute>
        let albumID: String?
        let kept: Int
    }

    private func count() async {
        let kept = store.keptIDs
        switch scope {
        case .all:
            matching = kept
        case .attributes where attributes.isEmpty, .album where albumID == nil:
            matching = []
        default:
            guard let filter else { matching = []; return }
            matching = nil
            let ids = await PhotoLibraryService.ids(matching: filter, among: kept)
            guard !Task.isCancelled else { return }
            matching = ids
        }
    }

    private var attributeSection: some View {
        Section {
            ForEach(MediaAttribute.allCases) { attribute in
                let isOn = attributes.contains(attribute)
                Button {
                    if isOn { attributes.remove(attribute) } else { attributes.insert(attribute) }
                } label: {
                    HStack {
                        Label { Text(attribute.title) } icon: { Image(systemName: attribute.systemImage) }
                        Spacer()
                        if isOn { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("resetAttribute.\(attribute.rawValue)")
            }
        } footer: {
            Text("選んだ属性のいずれかに当てはまる保持済みの写真だけをリセットします。")
        }
    }

    private var albumSection: some View {
        Section {
            Picker("アルバム", selection: $albumID) {
                Text("選択してください").tag(String?.none)
                ForEach(library.albums) { album in
                    Text(album.title).tag(Optional(album.id))
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("resetAlbumPicker")
        } footer: {
            Text("選んだアルバムに含まれる保持済みの写真だけをリセットします。")
        }
    }
}
