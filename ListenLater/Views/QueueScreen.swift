import SwiftUI

struct QueueScreen: View {
    enum SheetDestination: String, Identifiable {
        case addURL
        case about

        var id: String { rawValue }
    }

    let model: AppModel

    @State private var presentedSheet: SheetDestination?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NowPlayingCard(
                    playback: model.playback,
                    queue: model.queue
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Divider()

                queueList
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Listen Later")
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
                    if !model.queue.items.isEmpty {
                        EditButton()
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
                        youtubeIsConfigured: !AppConfiguration.youtubeAPIKey.isEmpty
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
        }
        .tint(Color(red: 0.12, green: 0.25, blue: 0.33))
    }

    @ViewBuilder
    private var queueList: some View {
        if model.queue.items.isEmpty {
            ContentUnavailableView {
                Label("Your Queue Is Empty", systemImage: "text.line.first.and.arrowtriangle.forward")
            } description: {
                Text("Share a podcast episode or YouTube video and choose “Add to Queue.”")
            } actions: {
                Button("Add a URL") {
                    presentedSheet = .addURL
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(model.queue.items) { item in
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
                                    item.isPlayed ? "Unplayed" : "Played",
                                    systemImage: item.isPlayed
                                        ? "arrow.counterclockwise"
                                        : "checkmark"
                                )
                            }
                            .tint(item.isPlayed ? .orange : .green)
                        }
                        .contextMenu {
                            Button {
                                model.queue.moveToPlayNext(
                                    item,
                                    after: model.playback.currentItemID
                                )
                            } label: {
                                Label("Play Next", systemImage: "text.insert")
                            }

                            Button {
                                togglePlayed(item)
                            } label: {
                                Label(
                                    item.isPlayed ? "Mark Unplayed" : "Mark Played",
                                    systemImage: item.isPlayed
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

                            Button(role: .destructive) {
                                model.queue.delete(item)
                                model.playback.currentItemWasDeleted()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("queue-item-\(item.id.uuidString)")
                    }
                    .onMove(perform: model.queue.move)
                } header: {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        Text(queueSummary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 74)
        }
    }

    private var queueSummary: String {
        let unplayed = model.queue.items.filter { !$0.isPlayed }.count
        return "\(unplayed)"
    }

    private func select(_ item: QueueItem) {
        if item.status == .unavailable {
            Task { await model.queue.retry(item) }
        } else {
            model.playback.start(item)
        }
    }

    private func togglePlayed(_ item: QueueItem) {
        if item.isPlayed {
            model.queue.markUnplayed(item)
        } else if model.playback.currentItemID == item.id {
            model.playback.playNext()
        } else {
            model.queue.markPlayed(item)
        }
    }
}
