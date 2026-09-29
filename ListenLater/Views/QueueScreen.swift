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
    @State private var toast: Toast?

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
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(toast: toast, dismiss: dismissToast)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task(id: toast?.id) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                dismissToast()
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
                    if upNextItems.count > 1 || editMode.isEditing {
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
            .onChange(of: model.playback.currentItemID) { _, newValue in
                guard newValue == nil else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    isPlayerCompact = false
                }
            }
            .onChange(of: upNextItems.count) { _, count in
                // Reordering needs two items; don't strand the list in edit
                // mode after its Done button disappears.
                if count < 2, editMode.isEditing {
                    editMode = .inactive
                }
            }
        }
    }

    @ViewBuilder
    private var queueList: some View {
        if model.queue.items.isEmpty {
            ContentUnavailableView {
                Label("Your Queue Is Empty", systemImage: "text.line.first.and.arrowtriangle.forward")
            } description: {
                Text("Share an X video, podcast episode, Instagram video, or YouTube link and choose “Add to Queue.”")
            } actions: {
                Button {
                    presentedSheet = .addURL
                } label: {
                    Text("Add a URL")
                        .foregroundStyle(Palette.onAccent)
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
                    Section {
                        ForEach(playedItems) { item in
                            queueRow(item)
                        }
                    } header: {
                        HStack {
                            Text("Played")
                            Spacer()
                            Button("Clear", action: clearPlayed)
                                .textCase(nil)
                                .accessibilityLabel("Clear played items")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .animation(.snappy, value: listLayout)
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
                    model.playback.currentItem != nil,
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

    /// Most recently finished first.
    private var playedItems: [QueueItem] {
        model.queue.items
            .filter(\.isInPlayedSection)
            .sorted {
                ($0.lastPlayedAt ?? $0.updatedAt)
                    > ($1.lastPlayedAt ?? $1.updatedAt)
            }
    }

    /// Changes when rows move, appear, disappear or change section, but not
    /// on progress saves, so only structural changes animate.
    private var listLayout: [String] {
        model.queue.items.map { "\($0.id.uuidString):\($0.isInPlayedSection)" }
    }

    private func queueRow(_ item: QueueItem) -> some View {
        QueueRow(
            item: item,
            isCurrent: model.playback.currentItemID == item.id,
            isPlaying: model.playback.currentItemID == item.id
                && model.playback.transportState.isPlaying
        )
        .contentShape(Rectangle())
        .onTapGesture { select(item) }
        .listRowBackground(
            model.playback.currentItemID == item.id
                ? Palette.playingRow
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
        // A full swipe deletes, which offers Undo. Marking an item played
        // discards its resume point, so that takes a deliberate tap.
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(item)
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
                delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("queue-item-\(item.id.uuidString)")
    }

    private func select(_ item: QueueItem) {
        if item.status == .unavailable {
            Task { await model.queue.retry(item) }
        } else if model.playback.currentItemID == item.id {
            // Restarting would rebuffer; the playing row toggles instead.
            model.playback.playOrPause()
        } else {
            model.playback.start(item)
        }
    }

    private func delete(_ item: QueueItem) {
        guard let snapshot = model.queue.delete(item) else { return }
        model.playback.currentItemWasDeleted()
        showToast(
            Toast(
                message: "Deleted “\(snapshot.title)”.",
                actionTitle: "Undo",
                action: { model.queue.restore([snapshot]) }
            )
        )
    }

    private func clearPlayed() {
        let snapshots = model.queue.delete(playedItems)
        guard !snapshots.isEmpty else { return }
        model.playback.currentItemWasDeleted()
        let count = snapshots.count
        showToast(
            Toast(
                message: count == 1
                    ? "Cleared 1 played item."
                    : "Cleared \(count) played items.",
                actionTitle: "Undo",
                action: { model.queue.restore(snapshots) }
            )
        )
    }

    private func showToast(_ newToast: Toast) {
        withAnimation(.snappy) {
            toast = newToast
        }
    }

    private func dismissToast() {
        withAnimation(.snappy) {
            toast = nil
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
