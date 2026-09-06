import SwiftUI

/// What the on-device conversation history costs, and how to reclaim it.
///
/// Clearing is safe rather than destructive: everything here is a copy of what
/// the connected computers hold, so the only cost of dropping it is fetching it
/// again.
struct HistoryStorageView: View {
    let client: any FeatureClient

    @State private var size: Int64?
    @State private var isClearing = false
    @State private var showingClearConfirmation = false

    private var sizeLabel: String {
        guard let size else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("On this device", value: sizeLabel)
                        .font(T3Typography.threadBody)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(T3Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("history-cache-size")

                    Text(
                        """
                        Conversations are kept on this device so threads open without waiting. \
                        Settled threads keep only their most recent turns.
                        """
                    )
                    .font(T3Typography.supporting)
                    .foregroundStyle(T3Colors.textTertiary)
                    .padding(.horizontal, 20)
                }

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Text(isClearing ? "Clearing…" : "Clear history")
                        .font(T3Typography.control)
                        .frame(maxWidth: .infinity, minHeight: T3Metrics.minimumTapTarget)
                        .background(T3Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isClearing || size == 0)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("clear-history-cache")
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(T3Colors.background)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSize() }
        .confirmationDialog(
            "Clear stored history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Threads will be downloaded again the next time you open them.")
        }
    }

    private func refreshSize() async {
        size = await client.historyCacheSize()
    }

    private func clear() async {
        isClearing = true
        await client.clearHistoryCache()
        await refreshSize()
        isClearing = false
    }
}
