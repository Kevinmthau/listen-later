import SwiftUI

/// Shown in place of the player and the list until something is queued.
/// Most links arrive through the share sheet, so this walks through the step
/// new users miss: finding Add to Queue there.
struct EmptyQueueView: View {
    /// Receives the text from the Paste button.
    let paste: (String) -> Void

    @State private var pastedText: String?

    var body: some View {
        // Centred when it fits; scrolls at the largest text sizes.
        ViewThatFits(in: .vertical) {
            VStack {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            ScrollView {
                content
            }
        }
        .onChange(of: pastedText) { _, text in
            guard let text else { return }
            pastedText = nil
            paste(text)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            WaveformTile()

            VStack(alignment: .leading, spacing: 6) {
                Text("Share something worth hearing")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Podcast episodes and videos you share from other apps wait here and play in order.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                Step(
                    symbol: "square.and.arrow.up",
                    title: "Tap Share",
                    detail: "In Podcasts, YouTube, X, Instagram or Safari."
                )
                Step(
                    symbol: "text.line.first.and.arrowtriangle.forward",
                    title: "Choose Add to Queue",
                    detail: "Don’t see it? Scroll the row of apps to the end and tap More, then Edit, then + beside Add to Queue."
                )
                Step(
                    symbol: "play.fill",
                    title: "Press Play",
                    detail: "The queue handles the rest."
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )

            HStack(spacing: 12) {
                Text("Copied a link?")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                PasteButton(payloadType: String.self) { strings in
                    pastedText = strings.first
                }
                .buttonBorderShape(.capsule)
                .tint(Palette.walnut)
            }
            .padding(.horizontal, 4)
        }
        .padding(20)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

/// The waveform on a podcast gradient: the queue's stand-in artwork when
/// nothing is playing.
struct WaveformTile: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: Palette.artworkGradient(for: .podcast),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "waveform")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

private struct Step: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }
}
