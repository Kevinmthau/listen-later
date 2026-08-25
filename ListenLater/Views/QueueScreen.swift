import SwiftUI

struct QueueScreen: View {
    enum SheetDestination: String, Identifiable {
        case addURL
        case about

        var id: String { rawValue }
    }

    let model: AppModel

    @State private var editMode: EditMode = .inactive
    @State private var presentedSheet: SheetDestination?
    @State private var isPlayerCompact = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NowPlayingCard(
                    playback: model.playback,
                    queue: model.queue,
                    isCompact: isPlayerCompact,
                    onExpand: expandPlayer,
                    onMinimize: minimizePlayer
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Divider()

                queueList
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("MushRadio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            presentedSheet = .about
                        } label: {
                            Label("Playback & Sync", systemImage: "info.circle")
                        }
                    } label: {
                        Image(systemName: model.isCloudBacked ? "icloud" : "icloud.slash")
                    }
                    .accessibilityLabel(
                        model.isCloudBacked ? "Cloud sync active" : "Cloud sync unavailable"
                    )
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if upNextItems.count > 1 {
                        EditButton()
                            .environment(\.editMode, $editMode)
                    }
                    Button {
                        presentedSheet = .addURL
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a URL")
                }
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .addURL:
                    AddURLView { url in
                        await model.queue.add(url: url)
                    }
                case .about:
                    PlaybackInfoView(
                        isCloudBacked: model.isCloudBacked,
                        persistenceNotice: model.persistenceNotice,
                        youtubeIsConfigured: !AppConfiguration.youtubeAPIKey.isEmpty,
                        videoGrabberIsConfigured:
                            AppConfiguration.videoGrabberEndpoint.scheme == "https"
                            && !AppConfiguration.videoGrabberAPIToken.isEmpty
                    )
                }
            }
            .alert(
                "Queue Update",
                isPresented: Binding(
                    get: { model.queue.lastErrorMessage != nil },
                    set: { newValue in
                        if !newValue {
                            model.queue.lastErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") { model.queue.lastErrorMessage = nil }
            } message: {
                Text(model.queue.lastErrorMessage ?? "")
            }
            .onChange(of: presentedSheet) { _, destination in
                if destination != nil {
                    model.playback.youtubePlayerWillBeCovered()
                }
            }
            .onChange(of: model.queue.lastErrorMessage) { _, message in
                if message != nil {
                    model.playback.youtubePlayerWillBeCovered()
                }
            }
            .onChange(of: model.playback.currentItemID) { _, _ in
                withAnimation(.snappy(duration: 0.25)) {
                    isPlayerCompact = false
                }
            }
        }
        .tint(Color(red: 0.12, green: 0.25, blue: 0.33))
    }

    @ViewBuilder
    private var queueList: some View {
        if model.queue.items.isEmpty {
            ContentUnavailableView {
                Label("Your Queue Is Empty", systemImage: "text.line.first.and.arrowtriangle.forward")
            } description: {
                Text("Share an X video, podcast episode, Instagram video, or YouTube link and choose “Add to Queue.”")
            } actions: {
                Button("Add a URL") {
                    presentedSheet = .addURL
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                if !upNextItems.isEmpty {
                    Section {
                        ForEach(upNextItems) { item in
                            queueRow(item)
                        }
                        .onMove(perform: model.queue.moveUpNext)
                    } header: {
                        HStack {
                            Text("Up Next")
                            Spacer()
                            Text(queueSummary)
                                .textCase(nil)
                        }
                    }
                }

                if !playedItems.isEmpty {
                    Section("Played") {
                        ForEach(playedItems) { item in
                            queueRow(item)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .environment(\.defaultMinListRowHeight, 74)
            .simultaneousGesture(
                playerMinimizingGesture,
                isEnabled: !editMode.isEditing
            )
        }
    }

    private var playerMinimizingGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let verticalDistance = value.translation.height
                guard
                    !isPlayerCompact,
                    !editMode.isEditing,
                    model.playback.currentItem?.source.isVideo == true,
                    verticalDistance < -24,
                    abs(verticalDistance) > abs(value.translation.width)
                else { return }

                minimizePlayer()
            }
    }

    private func expandPlayer() {
        withAnimation(.snappy(duration: 0.25)) {
            isPlayerCompact = false
        }
    }

    private func minimizePlayer() {
        withAnimation(.snappy(duration: 0.25)) {
            isPlayerCompact = true
        }
    }

    private var queueSummary: String {
        "\(upNextItems.count)"
    }

    private var upNextItems: [QueueItem] {
        model.queue.items.filter { !$0.isInPlayedSection }
    }

    private var playedItems: [QueueItem] {
        model.queue.items
            .filter(\.isInPlayedSection)
            .sorted {
                ($0.lastPlayedAt ?? $0.updatedAt)
                    < ($1.lastPlayedAt ?? $1.updatedAt)
            }
    }

    private func queueRow(_ item: QueueItem) -> some View {
        QueueRow(
            item: item,
            isCurrent: model.playback.currentItemID == item.id
        )
        .contentShape(Rectangle())
        .onTapGesture { select(item) }
        .listRowBackground(
            model.playback.currentItemID == item.id
                ? Color.accentColor.opacity(0.09)
                : Color(uiColor: .secondarySystemGroupedBackground)
        )
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if model.playback.currentItemID != item.id,
               !item.isInPlayedSection {
                Button {
                    model.queue.moveToPlayNext(
                        item,
                        after: model.playback.currentItemID
                    )
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.queue.delete(item)
                model.playback.currentItemWasDeleted()
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                togglePlayed(item)
            } label: {
                Label(
                    item.isInPlayedSection ? "Unplayed" : "Played",
                    systemImage: item.isInPlayedSection
                        ? "arrow.counterclockwise"
                        : "checkmark"
                )
            }
            .tint(item.isInPlayedSection ? .orange : .green)
        }
        .contextMenu {
            if model.playback.currentItemID != item.id,
               !item.isInPlayedSection {
                Button {
                    model.queue.moveToPlayNext(
                        item,
                        after: model.playback.currentItemID
                    )
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
            }

            Button {
                togglePlayed(item)
            } label: {
                Label(
                    item.isInPlayedSection ? "Mark Unplayed" : "Mark Played",
                    systemImage: item.isInPlayedSection
                        ? "arrow.counterclockwise"
                        : "checkmark.circle"
                )
            }

            if item.status == .unavailable {
                Button {
                    Task { await model.queue.retry(item) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if let shareURL = item.videoShareURL {
                ShareLink(
                    item: shareURL,
                    subject: Text(item.title)
                ) {
                    Label("Share Video", systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        model.playback.youtubePlayerWillBeCovered()
                    }
                )
                .accessibilityIdentifier("share-video-\(item.id.uuidString)")
            }

            Button(role: .destructive) {
                model.queue.delete(item)
                model.playback.currentItemWasDeleted()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("queue-item-\(item.id.uuidString)")
    }

    private func select(_ item: QueueItem) {
        if item.status == .unavailable {
            Task { await model.queue.retry(item) }
        } else {
            model.playback.start(item)
        }
    }

    private func togglePlayed(_ item: QueueItem) {
        if item.isInPlayedSection {
            model.queue.markUnplayed(item)
        } else if model.playback.currentItemID == item.id {
            model.playback.markCurrentPlayed()
        } else {
            model.queue.markPlayed(item)
        }
    }
}
