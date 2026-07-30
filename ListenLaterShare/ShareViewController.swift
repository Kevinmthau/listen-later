import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
private final class ShareStatusModel {
    enum State {
        case adding
        case added
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
            guard ProviderURLSupport.isHTTPURL(url) else {
                throw ShareError.unsupportedURL
            }

            let appGroup =
                Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
                ?? "group.com.kevinthau.ListenLater"
            let inbox = try SharedQueueInbox(appGroupIdentifier: appGroup)
            try inbox.enqueue(PendingShare(url: url))

            statusModel.state = .added
            try? await Task.sleep(for: .milliseconds(650))
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
                if case let .text(value) = item, let url = URL(string: value) {
                    return url
                }
            }
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let item = try await provider.sharedItem(
                    forTypeIdentifier: UTType.plainText.identifier
                )
                if case let .text(value) = item, let url = firstURL(in: value) {
                    return url
                }
            }
        }
        throw ShareError.missingURL
    }

    private func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           ProviderURLSupport.isHTTPURL(url)
        {
            return url
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first {
                ProviderURLSupport.isHTTPURL($0)
            }
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
    case unsupportedURL

    var errorDescription: String? {
        switch self {
        case .cancelled: "Adding was cancelled."
        case .missingURL: "This share does not contain a URL."
        case .unsupportedURL: "Only secure public HTTPS links can be added."
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
        case .adding: "Saving this link at the bottom of your listening queue."
        case .added: "Metadata will finish resolving in MushRadio."
        case let .failed(message): message
        }
    }
}
