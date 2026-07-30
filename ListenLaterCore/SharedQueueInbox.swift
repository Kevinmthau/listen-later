import Foundation

struct PendingShare: Codable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let createdAt: Date

    init(id: UUID = UUID(), url: URL, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
    }
}

struct PendingShareReceipt: Identifiable, Sendable {
    let share: PendingShare
    fileprivate let fileName: String

    var id: UUID {
        share.id
    }
}

struct PendingShareBatch: Sendable {
    let receipts: [PendingShareReceipt]
    let quarantinedFileCount: Int
}

struct SharedQueueInbox: Sendable {
    enum InboxError: LocalizedError {
        case appGroupUnavailable
        case quarantinedMalformedFiles(Int)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "The shared App Group container is unavailable."
            case let .quarantinedMalformedFiles(count):
                "\(count) damaged shared-link file\(count == 1 ? " was" : "s were") moved aside."
            }
        }
    }

    let directoryURL: URL
    private let notificationName: String

    init(
        directoryURL: URL,
        notificationName: String = "com.kevinthau.ListenLater.pending-share"
    ) {
        self.directoryURL = directoryURL
        self.notificationName = notificationName
    }

    init(appGroupIdentifier: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw InboxError.appGroupUnavailable
        }
        directoryURL = container.appending(path: "PendingShares", directoryHint: .isDirectory)
        notificationName = "\(appGroupIdentifier).pending-share"
    }

    func enqueue(_ share: PendingShare) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destination = directoryURL.appending(
            path: "\(share.createdAt.timeIntervalSince1970)-\(share.id.uuidString).json"
        )
        let data = try JSONEncoder.queueEncoder.encode(share)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        SharedQueueInboxObservation.post(name: notificationName)
    }

    func pending() throws -> [PendingShareReceipt] {
        let batch = try pendingBatch()
        if batch.quarantinedFileCount > 0 {
            throw InboxError.quarantinedMalformedFiles(
                batch.quarantinedFileCount
            )
        }
        return batch.receipts
    }

    func pendingBatch() throws -> PendingShareBatch {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var receipts: [PendingShareReceipt] = []
        var quarantinedCount = 0
        for file in files where file.pathExtension == "json" {
            do {
                let share = try JSONDecoder.queueDecoder.decode(
                    PendingShare.self,
                    from: Data(contentsOf: file)
                )
                receipts.append(
                    PendingShareReceipt(
                        share: share,
                        fileName: file.lastPathComponent
                    )
                )
            } catch {
                quarantine(file)
                quarantinedCount += 1
            }
        }
        let sortedReceipts = receipts.sorted {
            if $0.share.createdAt != $1.share.createdAt {
                return $0.share.createdAt < $1.share.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        return PendingShareBatch(
            receipts: sortedReceipts,
            quarantinedFileCount: quarantinedCount
        )
    }

    func observeEnqueues(
        _ handler: @escaping @Sendable () -> Void
    ) -> SharedQueueInboxObservation {
        SharedQueueInboxObservation(
            notificationName: notificationName,
            handler: handler
        )
    }

    private func quarantine(_ file: URL) {
        let quarantineDirectory = directoryURL.appending(
            path: "Quarantine",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true
            )
            let destination = quarantineDirectory.appending(
                path: "\(file.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).invalid"
            )
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            // A same-directory rename still prevents an unreadable JSON file
            // from becoming a permanent retry loop if quarantine creation
            // unexpectedly fails.
            let fallback = file
                .deletingPathExtension()
                .appendingPathExtension("invalid")
            try? FileManager.default.moveItem(at: file, to: fallback)
        }
    }

    func acknowledge(_ receipt: PendingShareReceipt) throws {
        let fileURL = directoryURL.appending(path: receipt.fileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Acknowledgement is idempotent so an already-completed delivery
            // cannot be turned back into a failure.
        }
    }
}

final class SharedQueueInboxObservation: @unchecked Sendable {
    private let notificationName: String
    private let handler: @Sendable () -> Void

    init(
        notificationName: String,
        handler: @escaping @Sendable () -> Void
    ) {
        self.notificationName = notificationName
        self.handler = handler

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            sharedQueueInboxNotificationCallback,
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(notificationName as CFString),
            nil
        )
    }

    fileprivate static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    fileprivate func receive() {
        handler()
    }
}

private let sharedQueueInboxNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    Unmanaged<SharedQueueInboxObservation>
        .fromOpaque(observer)
        .takeUnretainedValue()
        .receive()
}

private extension JSONEncoder {
    static var queueEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var queueDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
