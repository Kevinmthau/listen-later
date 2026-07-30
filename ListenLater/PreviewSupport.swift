#if DEBUG
import SwiftUI

@MainActor
private struct QueueScreenPreview: View {
    @State private var model: AppModel

    init(seedQueue: Bool) {
        let persistence = try! PersistenceController.makeContainer(inMemory: true)
        let model = AppModel(persistence: persistence, isDemoMode: true)
        if seedQueue {
            model.queue.seedDemoDataIfNeeded()
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        QueueScreen(model: model)
    }
}

#Preview("Queue") {
    QueueScreenPreview(seedQueue: true)
}

#Preview("Empty") {
    QueueScreenPreview(seedQueue: false)
}
#endif

