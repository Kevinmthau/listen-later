import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
private final class ShareStatusModel {
    enum State {
        case adding
        case added(LinkKind)
        case failed(String)
    }

    var state: State = .adding
}

final class ShareViewController: UIViewController {
    private let statusModel = ShareStatusModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(
            rootView: ShareStatusView(
                model: statusModel,
                cancel: { [weak self] in self?.cancel() }
            )
        )
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        Task { await addSharedURL() }
    }

    private func addSharedURL() async {
        do {
            let url = try await firstSharedURL()
            // Decide from the URL alone, so an unplayable link is refused
            // here instead of failing later in the app.
            let kind = LinkClassifier.classify(url)
            if case let .unsupported(reason) = kind {
                throw ShareError.unsupported(reason)
            }

            let appGroup =
                Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
                ?? "group.com.kevinthau.ListenLater"
            let inbox = try SharedQueueInbox(appGroupIdentifier: appGroup)
            try inbox.enqueue(PendingShare(url: url))

            statusModel.state = .added(kind)
            // A page MushRadio still has to search carries a caveat worth
            // a moment longer to read.
            try? await Task.sleep(for: .milliseconds(kind == .webPage ? 1_600 : 650))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            statusModel.state = .failed(error.localizedDescription)
        }
    }

    private func firstSharedURL() async throws -> URL {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let item = try await provider.sharedItem(
                    forTypeIdentifier: UTType.url.identifier
                )
                if case let .url(url) = item {
                    return url
                }
                if case let .text(value) = item,
                   let url = LinkClassifier.link(fromUserText: value)
                {
                    return url
                }
            }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let item = try await provider.sharedItem(
                    forTypeIdentifier: UTType.plainText.identifier
                )
                if case let .text(value) = item,
                   let url = LinkClassifier.link(fromUserText: value)
                {
                    return url
                }
            }
        }
        throw ShareError.missingURL
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: ShareError.cancelled)
    }
}

private enum SharedProviderItem: Sendable {
    case url(URL)
    case text(String)
}

private extension NSItemProvider {
    @MainActor
    func sharedItem(
        forTypeIdentifier identifier: String
    ) async throws -> SharedProviderItem? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: .url(url))
                } else if let value = item as? String {
                    continuation.resume(returning: .text(value))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private enum ShareError: LocalizedError {
    case cancelled
    case missingURL
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Adding was cancelled."
        case .missingURL: "This share doesn’t contain a link."
        case let .unsupported(reason): reason
        }
    }
}

private struct ShareStatusView: View {
    let model: ShareStatusModel
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Group {
                switch model.state {
                case .adding:
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Adding link")
                case .added:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolRenderingMode(.hierarchical)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .font(.system(size: 48))
            .frame(height: 52)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if case .failed = model.state {
                Button("Close", action: cancel)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var title: String {
        switch model.state {
        case .adding: "Adding to Queue"
        case .added: "Added to Queue"
        case .failed: "Couldn’t Add"
        }
    }

    private var message: String {
        switch model.state {
        case .adding:
            "Saving this link at the bottom of your queue."
        case .added(.webPage):
            "MushRadio will look for a podcast episode on this page when you open it."
        case .added(.youtubeVideo), .added(.socialVideo):
            "The video will be ready when you open MushRadio."
        case .added:
            "The episode will be ready when you open MushRadio."
        case let .failed(message):
            message
        }
    }
}
