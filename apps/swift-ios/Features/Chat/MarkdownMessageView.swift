import SwiftUI
import UIKit

struct MarkdownImageContext: Equatable, @unchecked Sendable {
    let threadID: String
    let workspaceRoot: String
    let resolver: any FeatureWorkspaceAssetResolving
    var sourceFilePath: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID
            && lhs.workspaceRoot == rhs.workspaceRoot
            && lhs.sourceFilePath == rhs.sourceFilePath
            && ObjectIdentifier(lhs.resolver) == ObjectIdentifier(rhs.resolver)
    }
}

/// Native chat Markdown with block-aware layout and Foundation inline parsing.
struct MarkdownMessageView: View {
    private struct RenderRequest: Hashable {
        let revision: MarkdownContentRevision
        let isStreaming: Bool
    }

    private let source: String
    private let revision: MarkdownContentRevision
    private let isStreaming: Bool
    private let copyActionTitle: String
    /// What "Copy message" yields. Differs from `source` when this view renders
    /// one block of a message that the transcript split across several cells.
    private let copySource: String
    private let imageContext: MarkdownImageContext?
    @State private var renderedDocument: MarkdownRenderedDocument?
    @State private var streamingRenderer = StreamingMarkdownRenderer()

    init(
        _ source: String,
        isStreaming: Bool = false,
        copyActionTitle: String = "Copy message",
        copySource: String? = nil,
        imageContext: MarkdownImageContext? = nil
    ) {
        self.source = source
        self.isStreaming = isStreaming
        self.copyActionTitle = copyActionTitle
        self.copySource = copySource ?? source
        self.imageContext = imageContext
        let revision = MarkdownContentRevision(source)
        self.revision = revision
        let initialDocument = if isStreaming {
            MarkdownRenderCache.shared.cachedDocument(for: revision)
        } else {
            MarkdownRenderCache.shared.documentImmediately(for: revision)
        }
        _renderedDocument = State(
            initialValue: initialDocument
        )
    }

    var body: some View {
        Group {
            if let displayDocument {
                MarkdownBlocksView(
                    blocks: displayDocument.blocks,
                    imageContext: imageContext
                )
            } else {
                // Parsing waits briefly so token-by-token streaming cancels stale revisions
                // instead of scheduling work for content the user will never see.
                Text(verbatim: source)
                    .font(T3Typography.threadBody)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityAction(named: copyActionTitle) {
            UIPasteboard.general.string = copySource
        }
        .task(id: RenderRequest(revision: revision, isStreaming: isStreaming)) {
            if !isStreaming {
                streamingRenderer.cancel()
                // Streaming -> complete usually keeps the final text; promote
                // the last streamed render instead of reparsing synchronously.
                if let renderedDocument, renderedDocument.revision == revision {
                    MarkdownRenderCache.shared.promote(renderedDocument)
                    return
                }
                renderedDocument = MarkdownRenderCache.shared.documentImmediately(for: revision)
                return
            }

            if let cached = MarkdownRenderCache.shared.cachedDocument(for: revision) {
                renderedDocument = cached
                return
            }

            // Hand the revision to a renderer that outlives this task. The
            // task modifier cancels on every revision, so rendering inside it
            // starves as soon as parsing is slower than the publish cadence;
            // the renderer instead keeps one render running and always picks
            // up the newest revision when it finishes (latest wins).
            streamingRenderer.submit(revision) { renderedDocument = $0 }
        }
        .onDisappear {
            streamingRenderer.cancel()
        }
    }

    private var displayDocument: MarkdownRenderedDocument? {
        if let renderedDocument, renderedDocument.revision == revision {
            return renderedDocument
        }
        // While streaming, a slightly stale document is better than flashing
        // back to plain text between renders. Streamed content only appends,
        // so require the stale document to be a prefix of the current source:
        // that accepts earlier snapshots of this message and rejects leftovers
        // from a recycled cell showing a different message.
        if isStreaming {
            if let renderedDocument,
               renderedDocument.revision.utf8Count <= revision.utf8Count,
               source.utf8.starts(with: renderedDocument.revision.source.utf8) {
                return renderedDocument
            }
            return nil
        }
        return MarkdownRenderCache.shared.documentImmediately(for: revision)
    }

}

/// Renders streaming revisions outside SwiftUI's task lifecycle so a render
/// in progress is never cancelled by the next revision arriving. One render
/// runs at a time; newer revisions replace the pending slot (latest wins) and
/// a 150ms throttle bounds the render cadence.
@MainActor
private final class StreamingMarkdownRenderer {
    private let throttle: Duration = .milliseconds(150)
    private var pending: MarkdownContentRevision?
    private var deliver: ((MarkdownRenderedDocument) -> Void)?
    private var renderTask: Task<Void, Never>?
    private var generation = 0
    private var lastRenderAt: Date?

    func submit(
        _ revision: MarkdownContentRevision,
        deliver: @escaping (MarkdownRenderedDocument) -> Void
    ) {
        pending = revision
        self.deliver = deliver
        guard renderTask == nil else { return }
        generation += 1
        let generation = generation
        renderTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    func cancel() {
        generation += 1
        renderTask?.cancel()
        renderTask = nil
        pending = nil
        deliver = nil
    }

    private func drain(generation: Int) async {
        // A cancelled drain can unwind after a replacement was already
        // started; only the current generation may clear the shared slot or
        // deliver, so two drains can never race or regress the document.
        defer {
            if self.generation == generation { renderTask = nil }
        }
        while self.generation == generation, let revision = pending {
            pending = nil
            if let lastRenderAt {
                let elapsed = Duration.seconds(-lastRenderAt.timeIntervalSinceNow)
                if elapsed < throttle {
                    try? await Task.sleep(for: throttle - elapsed)
                }
            }
            guard !Task.isCancelled else { return }
            // Render the newest revision available after the throttle wait.
            let target = pending ?? revision
            pending = nil
            guard let document = await MarkdownRenderCache.shared.document(
                for: target,
                isIntermediate: true
            ) else { continue }
            guard !Task.isCancelled, self.generation == generation else { return }
            lastRenderAt = .now
            deliver?(document)
        }
    }
}

private enum MarkdownTextColor: Equatable, Sendable {
    case primary
    case secondary

    var uiColor: UIColor {
        switch self {
        case .primary: T3Colors.uiTextPrimary
        case .secondary: T3Colors.uiTextSecondary
        }
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownRenderedBlock]
    let imageContext: MarkdownImageContext?
    var spacing: CGFloat = 12
    var textColor: MarkdownTextColor = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                // Unchanged blocks share inline runs by reference across
                // streaming revisions, so equatable comparison skips their
                // body and layout entirely; only the changed tail re-renders.
                MarkdownBlockView(
                    block: blocks[index],
                    imageContext: imageContext,
                    textColor: textColor
                )
                    .equatable()
            }
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownRenderedBlock
    let imageContext: MarkdownImageContext?
    let textColor: MarkdownTextColor

    @ViewBuilder
    var body: some View {
        switch block {
        case let .paragraph(inline):
            MarkdownInlineLabel(
                rendered: inline,
                lineSpacing: 4,
                textColor: textColor
            )

        case let .image(image):
            MarkdownImageView(image: image, context: imageContext)

        case let .heading(level, inline):
            MarkdownInlineLabel(rendered: inline, textColor: textColor)
                .padding(.top, level <= 2 ? 3 : 1)

        case let .unorderedList(items):
            MarkdownListView(
                items: items,
                start: nil,
                imageContext: imageContext,
                textColor: textColor
            )

        case let .orderedList(start, items):
            MarkdownListView(
                items: items,
                start: start,
                imageContext: imageContext,
                textColor: textColor
            )

        case let .blockquote(blocks):
            MarkdownBlocksView(
                blocks: blocks,
                imageContext: imageContext,
                spacing: 9,
                textColor: .secondary
            )
                .foregroundStyle(T3Colors.textSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(T3Colors.textTertiary)
                        .frame(width: 2)
                }

        case let .table(table):
            MarkdownTableView(
                table: table,
                textColor: textColor
            )

        case let .codeBlock(language, code, renderedCode):
            MarkdownCodeBlockView(
                language: language,
                code: code,
                renderedCode: renderedCode
            )

        case let .artifactTemplate(template):
            CodexArtifactTemplateView(template: template)

        case .thematicBreak:
            Rectangle()
                .fill(T3Colors.separator)
                .frame(height: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownRenderedTable
    let textColor: MarkdownTextColor

    private var columnWidths: [CGFloat] { table.columnWidths }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.header, isHeader: true)
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    tableRow(table.rows[rowIndex], isHeader: false)
                }
            }
            // A horizontal ScrollView still proposes the viewport width to its child.
            // Preserve the grid's measured column widths so it overflows and scrolls
            // instead of compressing prose columns into unreadable slivers.
            .fixedSize(horizontal: true, vertical: true)
            .background(T3Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(T3Colors.border, lineWidth: 1)
            }
        }
        .scrollIndicators(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(table.header.count) columns and \(table.rows.count) rows")
    }

    private func tableRow(
        _ cells: [MarkdownRenderedInline],
        isHeader: Bool
    ) -> some View {
        GridRow(alignment: .top) {
            ForEach(cells.indices, id: \.self) { columnIndex in
                MarkdownInlineLabel(
                    rendered: cells[columnIndex],
                    lineSpacing: 3,
                    textColor: textColor,
                    fillsWidth: false
                )
                    .frame(
                        width: columnWidths[columnIndex],
                        alignment: alignment(for: columnIndex)
                    )
                    .frame(
                        minHeight: 44,
                        maxHeight: .infinity,
                        alignment: alignment(for: columnIndex)
                    )
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .overlay(alignment: .trailing) {
                        if columnIndex < cells.count - 1 {
                            Rectangle()
                                .fill(T3Colors.separator)
                                .frame(width: 1)
                        }
                    }
            }
        }
        .background(isHeader ? T3Colors.surfaceRaised : T3Colors.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T3Colors.separator)
                .frame(height: 1)
        }
    }

    private func alignment(for columnIndex: Int) -> Alignment {
        guard table.alignments.indices.contains(columnIndex) else { return .leading }
        return switch table.alignments[columnIndex] {
        case .natural, .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

}

private struct MarkdownListView: View {
    let items: [MarkdownRenderedListItem]
    let start: Int?
    let imageContext: MarkdownImageContext?
    let textColor: MarkdownTextColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { offset in
                let item = items[offset]
                HStack(alignment: .top, spacing: 8) {
                    marker(for: item, offset: offset)
                        .frame(width: 24, height: 24, alignment: .trailing)
                    MarkdownBlocksView(
                        blocks: item.blocks,
                        imageContext: imageContext,
                        spacing: 7,
                        textColor: textColor
                    )
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownRenderedListItem, offset: Int) -> some View {
        if let task = item.task {
            Image(systemName: task == .complete ? "checkmark.square.fill" : "square")
                .font(T3Typography.control)
                .foregroundStyle(
                    task == .complete ? T3Colors.success : T3Colors.textSecondary
                )
                .accessibilityLabel(task == .complete ? "Completed" : "Not completed")
        } else if let start {
            Text("\(start + offset).")
                .font(T3Typography.supporting.monospaced())
                .foregroundStyle(T3Colors.textSecondary)
                .accessibilityLabel("Item \(start + offset)")
        } else {
            Text("•")
                .font(T3Typography.threadBody.weight(.semibold))
                .foregroundStyle(T3Colors.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

private struct MarkdownImageView: View {
    let image: MarkdownImage
    let context: MarkdownImageContext?

    @SwiftUI.Environment(\.openURL) private var openURL
    @State private var loadedImage: UIImage?
    @State private var previewURL: URL?
    @State private var failed = false

    private var classifiedSource: MarkdownImageSource {
        let basePath = context?.sourceFilePath.map {
            let isWindows = $0.contains("\\")
            let normalized = $0.replacingOccurrences(of: "\\", with: "/")
            let parent = (normalized as NSString).deletingLastPathComponent
            return isWindows ? parent.replacingOccurrences(of: "/", with: "\\") : parent
        } ?? context?.workspaceRoot
        return MarkdownImageSource.classify(image.source, workspaceRoot: basePath)
    }

    var body: some View {
        if classifiedSource != .blocked {
            Group {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 480)
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                        .font(.title2)
                        .foregroundStyle(T3Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .background(T3Colors.surfaceRaised)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(image.alternativeText.isEmpty ? "Image" : image.alternativeText)
            .accessibilityAddTraits(.isButton)
            .contentShape(Rectangle())
            .onTapGesture {
                if let previewURL { openURL(previewURL) }
            }
            .task(id: "\(image.source):\(context?.threadID ?? ""):\(context?.workspaceRoot ?? ""):\(context?.sourceFilePath ?? "")") {
                await loadImage()
            }
        }
    }

    @MainActor
    private func loadImage() async {
        previewURL = nil
        do {
            let url: URL
            switch classifiedSource {
            case let .direct(directURL):
                url = directURL
                if directURL.scheme == "http" || directURL.scheme == "https" {
                    previewURL = directURL
                }
            case let .workspaceFile(path):
                guard let context else { return }
                var components = URLComponents()
                components.scheme = "t3code"
                components.host = "media-preview"
                components.path = "/open"
                components.queryItems = [
                    URLQueryItem(name: "path", value: path),
                    URLQueryItem(name: "kind", value: "image"),
                ]
                previewURL = components.url
                url = try await context.resolver.mediaAssetURL(
                    threadID: context.threadID,
                    path: path
                )
            case .blocked:
                return
            }
            loadedImage = try await MarkdownImageLoader.load(url)
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}

private struct CodexArtifactTemplateView: View {
    let template: CodexArtifactTemplate
    @SwiftUI.Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName)
                    .font(T3Typography.threadBody.weight(.medium))
                    .foregroundStyle(T3Colors.textPrimary)
                Text(template.kind.label)
                    .font(T3Typography.supporting)
                    .foregroundStyle(T3Colors.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Use") {
                if let url = template.useURL { openURL(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private enum MarkdownImageLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    private static var session: URLSession { RemoteImageCache.session }

    static func load(_ url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        let data: Data
        if url.scheme?.lowercased() == "data" {
            guard let comma = url.absoluteString.firstIndex(of: ","),
                  url.absoluteString[..<comma].lowercased().contains(";base64"),
                  let decoded = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...])) else {
                throw MarkdownImageLoadingError.invalidImage
            }
            data = decoded
        } else {
            let response: URLResponse
            (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw MarkdownImageLoadingError.invalidResponse
            }
        }
        try Task.checkCancellation()
        let decoded = await Task.detached(priority: .utility) {
            UIImage(data: data)
        }.value
        try Task.checkCancellation()
        guard let decoded else { throw MarkdownImageLoadingError.invalidImage }
        let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(decoded, forKey: url as NSURL, cost: cost)
        return decoded
    }
}

private enum MarkdownImageLoadingError: Error {
    case invalidImage
    case invalidResponse
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    let renderedCode: MarkdownRenderedInline
    @State private var wrapOverride: Bool?

    private var wrapsLines: Bool {
        wrapOverride ?? MarkdownCodeBlockWrapping.wrapsByDefault(language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(T3Typography.supportingStrong)
                        .foregroundStyle(T3Colors.textTertiary)
                } else {
                    Text("CODE")
                        .font(T3Typography.supportingStrong)
                        .foregroundStyle(T3Colors.textTertiary)
                }
                Spacer(minLength: 8)
                Button {
                    wrapOverride = !wrapsLines
                } label: {
                    Label("Wrap", systemImage: "arrow.turn.down.left")
                        .font(T3Typography.control)
                        .foregroundStyle(wrapsLines ? T3Colors.accent : T3Colors.textSecondary)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityValue(wrapsLines ? "On" : "Off")
                .accessibilityHint("Toggles line wrapping for this code block")
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(T3Typography.control)
                        .foregroundStyle(T3Colors.textSecondary)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Copies this code block")
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 40)

            Rectangle()
                .fill(T3Colors.separator)
                .frame(height: 1)

            if wrapsLines {
                MarkdownInlineLabel(rendered: renderedCode, lineSpacing: 3)
                    .padding(13)
            } else {
                ScrollView(.horizontal) {
                    MarkdownInlineLabel(
                        rendered: renderedCode,
                        lineSpacing: 3,
                        wrapsLines: false
                    )
                        .padding(13)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(T3Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(T3Colors.border, lineWidth: 1)
        }
    }
}

enum MarkdownCodeBlockWrapping {
    private static let proseLanguages: Set<String> = [
        "markdown",
        "md",
        "plain",
        "plaintext",
        "text",
        "text/plain",
        "txt",
    ]

    static func wrapsByDefault(language: String?) -> Bool {
        guard let language else { return false }
        return proseLanguages.contains(language.lowercased())
    }
}

/// Wrapping text as a plain SwiftUI `Text`.
///
/// The representable below instantiates a `UITextView` — a whole TextKit stack —
/// for every block, and that happens during the sizing pass, which is what makes
/// a heavy message cost 15–23ms to measure. A `Text` needs no UIKit view at all.
///
/// The parser emits `AttributedString` carrying `inlinePresentationIntent`, but
/// `Text` only resolves that intent against fonts it owns — under a `Font` built
/// from a `UIFont` the bold and italic spans silently render plain. So the runs
/// are resolved to concrete fonts up front, by the same code the text view uses.
private struct MarkdownInlineLabel: View {
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rendered: MarkdownRenderedInline
    var lineSpacing: CGFloat = 0
    var textColor: MarkdownTextColor = .primary
    /// False for code blocks, which lay out at their natural width inside a
    /// horizontal scroll view rather than wrapping.
    var wrapsLines = true
    /// False for table cells, which already sit in a fixed-width column and
    /// must hug their text so the column's alignment has something to place.
    var fillsWidth = true

    var body: some View {
        Text(
            MarkdownSelectableTextAttributes.attributedText(
                from: rendered,
                foregroundColor: textColor.uiColor,
                dynamicTypeSize: dynamicTypeSize
            )
        )
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: !wrapsLines, vertical: true)
        .modifier(MarkdownLabelWidth(isEnabled: wrapsLines && fillsWidth))
    }
}

private struct MarkdownLabelWidth: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}

enum MarkdownSelectableTextAttributes {
    /// Resolves each run's Markdown intent to a concrete font and colour.
    ///
    /// `Text` only applies `inlinePresentationIntent` against fonts it owns, so
    /// under a `Font` built from a `UIFont` bold and italic spans silently
    /// render plain. Resolving them here keeps that from happening.
    @MainActor
    static func attributedText(
        from rendered: MarkdownRenderedInline,
        foregroundColor: UIColor,
        dynamicTypeSize: DynamicTypeSize
    ) -> AttributedString {
        var result = rendered.attributedText
        for run in rendered.attributedText.runs {
            let intent = run.inlinePresentationIntent
            // Scope matters: UIKit also defines `font`, and a UIKit font
            // attribute is invisible to `Text`.
            var attributes = AttributeContainer()
            attributes.swiftUI.font = Font(
                font(for: rendered.style, intent: intent, dynamicTypeSize: dynamicTypeSize)
            )
            attributes.swiftUI.foregroundColor = Color(
                uiColor: run.link == nil ? foregroundColor : T3Colors.uiAccent
            )
            if intent?.contains(.code) == true {
                attributes.swiftUI.backgroundColor = Color(uiColor: T3Colors.uiSurfaceRaised)
            }
            if intent?.contains(.strikethrough) == true {
                attributes.swiftUI.strikethroughStyle = .single
            }
            result[run.range].mergeAttributes(attributes)
        }
        return result
    }

    /// Resolves one run's intent onto the block's base font. Internal so the
    /// trait resolution can be tested directly: SwiftUI's `Font` is opaque, so
    /// the attributed string it ends up in cannot be inspected for bold.
    @MainActor
    static func font(
        for style: MarkdownInlineStyle,
        intent: InlinePresentationIntent?,
        dynamicTypeSize: DynamicTypeSize
    ) -> UIFont {
        var font = style.uiFont(dynamicTypeSize: dynamicTypeSize)
        if intent?.contains(.code) == true, style != .code {
            font = UIFont.monospacedSystemFont(
                ofSize: font.pointSize,
                weight: .regular
            )
        }

        let addsBold = intent?.contains(.stronglyEmphasized) == true
        let addsItalic = intent?.contains(.emphasized) == true
        guard addsBold || addsItalic else { return font }

        var traits = font.fontDescriptor.symbolicTraits
        if addsBold {
            traits.insert(.traitBold)
        }
        if addsItalic {
            traits.insert(.traitItalic)
        }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: 0)
        }
        return font
    }
}

enum MarkdownInlineFormatter {
    static func format(_ source: String) -> AttributedString {
        (
            try? AttributedString(
                markdown: source,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        ) ?? AttributedString(source)
    }
}
