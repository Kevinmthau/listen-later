#if DEBUG
import SwiftData
import SwiftUI

@MainActor
private struct QueueScreenPreview: View {
    @State private var model: AppModel

    init(seedQueue: Bool, startFirstItem: Bool = false) {
        let persistence = try! PersistenceController.makeContainer(inMemory: true)
        let model = AppModel(persistence: persistence, isDemoMode: true)
        if seedQueue {
            model.queue.seedDemoDataIfNeeded()
            if startFirstItem, let first = model.queue.items.first {
                model.playback.start(first, autoplay: false)
            }
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        QueueScreen(model: model)
    }
}

/// Every state a queue row can be in, to check layout, colour and text size
/// together rather than one state at a time.
@MainActor
private struct QueueRowGallery: View {
    private struct Row: Identifiable {
        let id = UUID()
        let item: QueueItem
        var isCurrent = false
        var isPlaying = false
    }

    @State private var container: ModelContainer
    @State private var rows: [Row]

    init() {
        let container = try! PersistenceController.makeContainer(inMemory: true).container
        let context = container.mainContext

        func item(
            _ title: String,
            _ subtitle: String,
            source: MediaSource,
            status: QueueItemStatus = .ready,
            duration: TimeInterval = 0,
            position: TimeInterval = 0,
            rank: Double
        ) -> QueueItem {
            let item = QueueItem(
                originalURL: URL(string: "https://example.com/\(Int(rank))")!,
                title: title,
                subtitle: subtitle,
                source: source,
                status: status,
                sortRank: rank
            )
            item.duration = duration
            item.playbackPosition = position
            context.insert(item)
            return item
        }

        let playing = item(
            "The case for slower technology",
            "Signals & Threads",
            source: .podcast,
            duration: 3_248,
            position: 742,
            rank: 1
        )
        let paused = item(
            "A short reel about good objects",
            "@goodobjects",
            source: .socialVideo,
            duration: 48,
            position: 12,
            rank: 2
        )
        let youtube = item(
            "How a record becomes a memory",
            "Field Notes",
            source: .youtube,
            duration: 1_106,
            rank: 3
        )
        let inProgress = item(
            "Designing for calm",
            "Good Objects",
            source: .podcast,
            duration: 2_681,
            position: 900,
            rank: 4
        )
        let resolving = item("Podcast episode", "", source: .podcast, status: .resolving, rank: 5)
        let unavailable = item("Podcast episode", "", source: .podcast, status: .unavailable, rank: 6)
        unavailable.unavailableReason =
            "This page doesn’t link to a podcast feed, so MushRadio can’t find the episode."
        let played = item("An older favourite", "Signals & Threads", source: .podcast, duration: 1_800, rank: 7)
        played.isPlayed = true

        _container = State(initialValue: container)
        _rows = State(initialValue: [
            Row(item: playing, isCurrent: true, isPlaying: true),
            Row(item: paused, isCurrent: true),
            Row(item: youtube),
            Row(item: inProgress),
            Row(item: resolving),
            Row(item: unavailable),
            Row(item: played),
        ])
    }

    var body: some View {
        List(rows) { row in
            QueueRow(item: row.item, isCurrent: row.isCurrent, isPlaying: row.isPlaying)
        }
        .listStyle(.plain)
    }
}

#Preview("Queue") {
    QueueScreenPreview(seedQueue: true)
}

#Preview("Queue · Dark") {
    QueueScreenPreview(seedQueue: true)
        .preferredColorScheme(.dark)
}

#Preview("Queue · Largest text") {
    QueueScreenPreview(seedQueue: true)
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Paused podcast") {
    QueueScreenPreview(seedQueue: true, startFirstItem: true)
}

#Preview("Empty") {
    QueueScreenPreview(seedQueue: false)
}

#Preview("Rows") {
    QueueRowGallery()
}

#Preview("Rows · Dark, largest text") {
    QueueRowGallery()
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
