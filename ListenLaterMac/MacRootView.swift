import SwiftUI
import UniformTypeIdentifiers

struct MacRootView: View {
    @Bindable var model: MacAppModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            queueList
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            MacPlayerDetailView(model: model, item: model.selectedItem)
        }
        .navigationTitle("MushRadio")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.presentedSheet = .addLink
                } label: {
                    Label("Add Link", systemImage: "link.badge.plus")
                }
                .help("Add a podcast or video link")

                Button {
                    model.isShowingImporter = true
                } label: {
                    Label("Import Videos", systemImage: "square.and.arrow.down")
                }
                .help("Copy movie files into MushRadio")
            }
        }
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .addLink:
                MacAddLinkView(model: model)
            }
        }
        .fileImporter(
            isPresented: $model.isShowingImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await model.importVideos(from: urls) }
            case let .failure(error):
                model.userMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let movieURLs = urls.filter { $0.isFileURL }
            guard !movieURLs.isEmpty else { return false }
            Task { await model.importVideos(from: movieURLs) }
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [8]))
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .alert(
            "MushRadio",
            isPresented: Binding(
                get: { model.userMessage != nil },
                set: { if !$0 { model.userMessage = nil } }
            )
        ) {
            if model.canUndoDeletion {
                Button("Undo") { Task { await model.undoDeletion() } }
            }
            Button("OK") { model.userMessage = nil }
        } message: {
            Text(model.userMessage ?? "")
        }
        .onChange(of: model.selectedItemID) { _, _ in
            guard let item = model.selectedItem else { return }
            Task { await model.playback.select(item) }
        }
    }

    @ViewBuilder
    private var queueList: some View {
        if model.items.isEmpty {
            ContentUnavailableView {
                Label("Your queue is empty", systemImage: "waveform")
            } description: {
                Text("Add a link or import movie files from this Mac.")
            } actions: {
                Button("Add Link") { model.presentedSheet = .addLink }
                Button("Import Videos") { model.isShowingImporter = true }
            }
        } else {
            List(selection: $model.selectedItemID) {
                Section("Up Next") {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        MacQueueRow(
                            item: item,
                            isAvailable: model.localAvailability[item.id] ?? true,
                            isPlaying: model.playback.currentItemID == item.id
                                && model.playback.state == .playing
                        )
                        .tag(item.id)
                        .contextMenu {
                            Button("Play") {
                                Task { await model.playback.select(item); await model.playback.play() }
                            }
                            Button(item.isPlayed ? "Mark Unplayed" : "Mark Played") {
                                model.setPlayed(item, played: !item.isPlayed)
                            }
                            Divider()
                            Button("Move Up") { model.move(item, offset: -1) }
                                .disabled(index == 0)
                            Button("Move Down") { model.move(item, offset: 1) }
                                .disabled(index == model.items.count - 1)
                            if item.source != .localVideo && item.source != .unknown {
                                Button("Open Original Link") { model.openOriginal(item) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                Task { await model.delete(item) }
                            }
                        }
                        .accessibilityAction(named: "Play") {
                            Task { await model.playback.select(item); await model.playback.play() }
                        }
                    }
                    .onMove(perform: model.move)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct MacQueueRow: View {
    let item: QueueItem
    let isAvailable: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.source.symbolName)
                .font(.title3)
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(item.sourceName)
                    if item.source == .localVideo, !isAvailable {
                        Label("Not on this Mac", systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.orange)
                    } else if item.isPlayed {
                        Label("Played", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if item.duration > 0 {
                        Text(item.duration.queueCompactDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Playing")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
