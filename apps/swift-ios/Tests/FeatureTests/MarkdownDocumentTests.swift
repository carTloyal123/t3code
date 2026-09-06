import Foundation
import SwiftUI
import Testing
import UIKit
@testable import T3Code

@Suite("Chat Markdown")
struct MarkdownDocumentTests {
    @Test
    func codexFileCitationsBecomeWorkspaceLinks() {
        let document = MarkdownDocument(
            parsing: #"See :codex-file-citation{path="docs/My file%#?.md" line_range_start="12"}."#
        )

        #expect(
            document.blocks == [
                .paragraph("See [My file%#?.md](<docs/My file%25%23%3F.md#L12>)."),
            ]
        )
    }

    @Test
    func codexFileCitationsEscapeLabelsAndDestinations() {
        let document = MarkdownDocument(
            parsing: #":codex-file-citation{path=" reports/*draft*_[copy]`<&).txt "}"#
        )

        #expect(
            document.blocks == [
                .paragraph(
                    #"[\*draft\*\_\[copy\]\`\<\&).txt](<reports/*draft*_[copy]`%3C&).txt>)"#
                ),
            ]
        )

        #expect(
            CodexMarkdownDirectives.fileCitation(
                from: ":codex-file-citation{path=\"reports/a<b>\r\n.txt\"}"
            ) == "[a\\<b>\r\n.txt](<reports/a%3Cb%3E%0D%0A.txt>)"
        )
    }

    @Test
    func codexFileCitationEndIsQuoteAwareAndSupportsSingleQuotes() {
        let document = MarkdownDocument(
            parsing: #":codex-file-citation{path='reports/a}b file.md' line_range_start=' 9 '}"#
        )

        #expect(document.blocks == [.paragraph("[a}b file.md](<reports/a}b file.md#L9>)")])

        #expect(
            MarkdownDocument(
                parsing: ":codex-file-citation{path=reports/unquoted.md line_range_start=3}"
            ).blocks == [.paragraph("[unquoted.md](<reports/unquoted.md#L3>)")]
        )
    }

    @Test
    func codexFileCitationsStayLiteralInEscapedCodeAndReferenceLinks() {
        let directive = #":codex-file-citation{path="src/file.swift"}"#
        let document = MarkdownDocument(
            parsing: """
            \\`\(directive)\\`

            [outer [nested \(directive)] label][ref]

            [ref]: docs/reference.md
            """
        )

        #expect(document.blocks[0] == .paragraph("\\`[file.swift](<src/file.swift>)\\`"))
        #expect(document.blocks[1] == .paragraph("[outer [nested \(directive)] label][ref]"))
    }

    @Test
    func codexFileCitationsStayLiteralInCodeAndLinks() {
        let directive = #":codex-file-citation{path="src/file.swift" line_range_start="2"}"#
        let document = MarkdownDocument(
            parsing: """
            `\(directive)`

                \(directive)

            ```text
            \(directive)
            ```

            [existing \(directive)](docs/existing.md)
            """
        )

        #expect(document.blocks[0] == .paragraph("`\(directive)`"))
        #expect(document.blocks[1] == .paragraph("    \(directive)"))
        #expect(document.blocks[2] == .codeBlock(language: "text", code: directive))
        #expect(document.blocks[3] == .paragraph("[existing \(directive)](docs/existing.md)"))
    }

    @Test
    func malformedAndIncompleteCodexDirectivesStayLiteral() {
        let missingPath = #":codex-file-citation{line_range_start="4"}"#
        let incomplete = #":codex-file-citation{path="src/file.swift""#
        let invalidLine = #":codex-file-citation{path="src/file.swift" line_range_start="zero"}"#
        let document = MarkdownDocument(parsing: "\(missingPath)\n\(incomplete)\n\(invalidLine)")

        #expect(
            document.blocks == [
                .paragraph("\(missingPath)\n\(incomplete)\n[file.swift](<src/file.swift>)"),
            ]
        )
    }

    @Test
    func parsesArtifactTemplatesInsideNestedLists() {
        let directive = #"::artifact-template{artifact_kind="document" display_name="Release notes template" skill_directory="/templates/release notes" skill_name="artifact-template-release" gallery_kind="imagegen"}"#
        let document = MarkdownDocument(parsing: "- Templates\n  - \(directive)")
        guard case let .unorderedList(items) = document.blocks.first,
              case let .unorderedList(children) = items.first?.blocks.last,
              case let .artifactTemplate(template) = children.first?.blocks.first else {
            Issue.record("Expected a nested artifact template")
            return
        }

        #expect(template.displayName == "Release notes template")
        #expect(template.kind == .document)
        #expect(template.usePrompt == "Create a document using this $artifact-template-release about…")
        #expect(template.useURL?.scheme == "t3code")
    }

    @Test
    func invalidArtifactTemplateAttributesStayLiteral() {
        for directive in [
            #"::artifact-template{artifact_kind="video" display_name="Demo" skill_directory="/tmp" skill_name="artifact-template-demo"}"#,
            #"::artifact-template{artifact_kind="image" display_name="Demo" skill_directory="relative" skill_name="artifact-template-demo"}"#,
            #"::artifact-template{artifact_kind="image" display_name="Demo" skill_directory="C:\\templates" skill_name="wrong"}"#,
            #"::artifact-template{artifact_kind="image" display_name="Demo" skill_directory="/tmp" skill_name="artifact-template-demo" gallery_kind="unknown"}"#,
        ] {
            #expect(MarkdownDocument(parsing: directive).blocks == [.paragraph(directive)])
        }

        let validButIndented = #"    ::artifact-template{artifact_kind="document" display_name="Demo" skill_directory="/tmp" skill_name="artifact-template-demo"}"#
        #expect(
            MarkdownDocument(parsing: validButIndented).blocks == [.paragraph(validButIndented)]
        )
    }

    @Test
    func relativeImagesCanResolveFromTheViewedSourceFile() {
        #expect(
            MarkdownImageSource.classify(
                "images/preview.png",
                workspaceRoot: "/workspace/project/docs"
            ) == .workspaceFile("/workspace/project/docs/images/preview.png")
        )
    }

    @Test
    func workspaceFileLinksResolveRelativeAbsoluteAndSpacedPaths() throws {
        #expect(
            MarkdownWorkspaceFileLink.relativePath(
                for: try #require(URL(string: "docs/My%20Folder/checklist.xml")),
                workspaceRoot: "/workspace/project"
            ) == "docs/My Folder/checklist.xml"
        )
        #expect(
            MarkdownWorkspaceFileLink.relativePath(
                for: try #require(URL(string: "Updated%20cutover%20checklist.md")),
                workspaceRoot: "/workspace/project"
            ) == "Updated cutover checklist.md"
        )
        #expect(
            MarkdownWorkspaceFileLink.relativePath(
                for: try #require(URL(string: "file:///workspace/project/src/main.swift#L18")),
                workspaceRoot: "/workspace/project"
            ) == "src/main.swift"
        )
        #expect(
            MarkdownWorkspaceFileLink.relativePath(
                for: try #require(URL(string: "/workspace/project/src/a%23b%3Fc%25.swift#L2")),
                workspaceRoot: "/workspace/project"
            ) == "src/a#b?c%.swift"
        )
        #expect(
            MarkdownWorkspaceFileLink.relativePath(
                for: try #require(
                    URL(string: "file:///workspace/project/src/a%23b%3Fc%25.swift#L2")
                ),
                workspaceRoot: "/workspace/project"
            ) == "src/a#b?c%.swift"
        )
    }

    @Test
    func workspaceFileLinksRejectExternalAndEscapedPaths() throws {
        for value in ["https://example.com/file.md", "javascript:alert(1)", "../private.md",
                      "file:///other/project/file.md"] {
            #expect(
                MarkdownWorkspaceFileLink.relativePath(
                    for: try #require(URL(string: value)),
                    workspaceRoot: "/workspace/project"
                ) == nil
            )
        }
    }

    @Test
    func separatesHeadingsParagraphsAndListKinds() {
        let document = MarkdownDocument(
            parsing: """
            # Release notes

            Includes **important** details.

            - First
            - [x] Shipped
            - [ ] Follow up

            3. Third
            4. Fourth
            """
        )

        #expect(
            document.blocks == [
                .heading(level: 1, text: "Release notes"),
                .paragraph("Includes **important** details."),
                .unorderedList([
                    MarkdownListItem(task: nil, blocks: [.paragraph("First")]),
                    MarkdownListItem(task: .complete, blocks: [.paragraph("Shipped")]),
                    MarkdownListItem(task: .incomplete, blocks: [.paragraph("Follow up")]),
                ]),
                .orderedList(
                    start: 3,
                    items: [
                        MarkdownListItem(task: nil, blocks: [.paragraph("Third")]),
                        MarkdownListItem(task: nil, blocks: [.paragraph("Fourth")]),
                    ]
                ),
            ]
        )
    }

    @Test
    func separatesMarkdownImagesFromSurroundingParagraphText() {
        let document = MarkdownDocument(
            parsing: "Before ![Build result](images/result.png) after\n\n![Preview](<shot one.png> \"Title\")"
        )

        #expect(
            document.blocks == [
                .paragraph("Before"),
                .image(MarkdownImage(source: "images/result.png", alternativeText: "Build result")),
                .paragraph("after"),
                .image(MarkdownImage(source: "<shot one.png>", alternativeText: "Preview")),
            ]
        )
    }

    @Test
    func markdownImageSourcesDistinguishRemoteAndWorkspaceImages() {
        #expect(
            MarkdownImageSource.classify("https://example.com/image.png", workspaceRoot: "/repo")
                == .direct(URL(string: "https://example.com/image.png")!)
        )
        #expect(
            MarkdownImageSource.classify("//cdn.example.com/image.png")
                == .direct(URL(string: "https://cdn.example.com/image.png")!)
        )
        #expect(
            MarkdownImageSource.classify("images/result.png", workspaceRoot: "/workspace/project")
                == .workspaceFile("/workspace/project/images/result.png")
        )
        #expect(
            MarkdownImageSource.classify(
                "images/result.png",
                workspaceRoot: #"C:\Users\theo\project"#
            ) == .workspaceFile(#"C:\Users\theo\project\images\result.png"#)
        )
        #expect(
            MarkdownImageSource.classify("file:///workspace/project/image%20one.png")
                == .workspaceFile("/workspace/project/image one.png")
        )
        #expect(
            MarkdownImageSource.classify("file://server/share/image.png")
                == .workspaceFile(#"\\server\share\image.png"#)
        )
        #expect(
            MarkdownImageSource.classify("/C:/Users/theo/image.png")
                == .workspaceFile("C:/Users/theo/image.png")
        )
    }

    @Test
    func markdownImageSourcesRejectUnsafeAndUnresolvedDestinations() {
        for source in ["", "#image", "?image=1", "image.png", "~/image.png",
                       "javascript:alert(1)", "ftp://example.com/image.png",
                       "content://media/image/1"] {
            #expect(MarkdownImageSource.classify(source) == .blocked)
        }
    }

    @Test
    func preservesNestedStructureInsideQuotesAndLists() {
        let document = MarkdownDocument(
            parsing: """
            > ## Heads up
            > Read this first.
            >
            > - Quoted item

            - Parent
              - Nested child
            """
        )

        guard case let .blockquote(quote) = document.blocks.first else {
            Issue.record("Expected a block quote")
            return
        }
        #expect(
            quote.blocks == [
                .heading(level: 2, text: "Heads up"),
                .paragraph("Read this first."),
                .unorderedList([
                    MarkdownListItem(task: nil, blocks: [.paragraph("Quoted item")]),
                ]),
            ]
        )

        guard case let .unorderedList(items) = document.blocks.last else {
            Issue.record("Expected an unordered list")
            return
        }
        #expect(
            items == [
                MarkdownListItem(
                    task: nil,
                    blocks: [
                        .paragraph("Parent"),
                        .unorderedList([
                            MarkdownListItem(task: nil, blocks: [.paragraph("Nested child")]),
                        ]),
                    ]
                ),
            ]
        )
    }

    @Test
    func parsesTablesWithAlignmentEscapesAndNormalizedRows() {
        let document = MarkdownDocument(
            parsing: """
            | Name | Status | Notes |
            | :--- | :---: | ---: |
            | Parser | Ready | **Fast** |
            | Escaped \\| pipe | ``a|b`` | [Docs](https://example.com) |
            | Short | Row |
            | Extra | cells | stay | ignored |
            """
        )

        #expect(
            document.blocks == [
                .table(
                    MarkdownTable(
                        header: ["Name", "Status", "Notes"],
                        alignments: [.leading, .center, .trailing],
                        rows: [
                            ["Parser", "Ready", "**Fast**"],
                            ["Escaped \\| pipe", "``a|b``", "[Docs](https://example.com)"],
                            ["Short", "Row", ""],
                            ["Extra", "cells", "stay"],
                        ]
                    )
                ),
            ]
        )
    }

    @Test
    func unmatchedBacktickDoesNotHideLaterTableSeparators() {
        let document = MarkdownDocument(
            parsing: """
            Left | Middle | Right
            --- | --- | ---
            x | `y | z
            """
        )

        #expect(
            document.blocks == [
                .table(
                    MarkdownTable(
                        header: ["Left", "Middle", "Right"],
                        alignments: [.natural, .natural, .natural],
                        rows: [["x", "`y", "z"]]
                    )
                ),
            ]
        )
    }

    @Test
    func rejectsTableDelimiterCellsWithFewerThanThreeDashes() {
        let document = MarkdownDocument(
            parsing: """
            Name | Status
            -- | ---
            Parser | Ready
            """
        )

        #expect(
            document.blocks == [
                .paragraph("Name | Status\n-- | ---\nParser | Ready"),
            ]
        )
    }

    @Test
    func rendersTableCellsThroughTheInlineMarkdownCache() throws {
        let source = """
        Label | Value
        --- | ---
        **Build** | `green`
        """
        let revision = MarkdownContentRevision(source)
        let rendered = try #require(
            MarkdownRenderCache.shared.documentImmediately(for: revision)
        )
        guard case let .table(table) = rendered.blocks.first else {
            Issue.record("Expected a rendered table")
            return
        }

        #expect(String(table.header[0].attributedText.characters) == "Label")
        #expect(String(table.rows[0][0].attributedText.characters) == "Build")
        #expect(
            table.rows[0][0].attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
        #expect(
            table.rows[0][1].attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.code) == true
            }
        )
    }

    @Test
    func fencedCodeKeepsLanguageAndContentsLiteral() {
        let document = MarkdownDocument(
            parsing: """
            ```swift
            let value = "**not emphasis**"
              print(value)
            ```
            """
        )

        #expect(
            document.blocks == [
                .codeBlock(
                    language: "swift",
                    code: "let value = \"**not emphasis**\"\n  print(value)"
                ),
            ]
        )
    }

    @Test
    func unclosedFenceConsumesTheRemainingMessage() {
        let document = MarkdownDocument(
            parsing: """
            ~~~console
            pnpm test
            no closing fence
            """
        )

        #expect(
            document.blocks == [
                .codeBlock(language: "console", code: "pnpm test\nno closing fence"),
            ]
        )
    }

    @Test
    func plaintextCodeBlocksWrapByDefault() {
        for language in ["text", "TEXT", "txt", "plaintext", "plain", "md", "markdown"] {
            #expect(MarkdownCodeBlockWrapping.wrapsByDefault(language: language))
        }

        for language in [nil, "swift", "typescript", "console"] {
            #expect(!MarkdownCodeBlockWrapping.wrapsByDefault(language: language))
        }
    }

    @Test
    func parsesSetextHeadingsAndNormalizesWindowsNewlines() {
        let document = MarkdownDocument(parsing: "Heading\r\n=======\r\n\r\nBody")

        #expect(
            document.blocks == [
                .heading(level: 1, text: "Heading"),
                .paragraph("Body"),
            ]
        )
    }

    @Test
    func inlineFormatterRetainsEmphasisCodeAndLinks() {
        let formatted = MarkdownInlineFormatter.format(
            "Use **bold**, *emphasis*, `code`, and [docs](https://example.com)."
        )
        let runs = Array(formatted.runs)

        #expect(String(formatted.characters) == "Use bold, emphasis, code, and docs.")
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(runs.contains { $0.link == URL(string: "https://example.com") })
    }

    @Test @MainActor
    func inlineAttributesPreserveFormattingAndLinks() throws {
        let revision = MarkdownContentRevision(
            "Use **bold**, *emphasis*, `code`, ~~removed~~, and [docs](https://example.com)."
        )
        let document = try #require(
            MarkdownRenderCache.shared.documentImmediately(for: revision)
        )
        guard case let .paragraph(inline) = document.blocks.first else {
            Issue.record("Expected a rendered paragraph")
            return
        }

        let attributed = MarkdownSelectableTextAttributes.attributedText(
            from: inline,
            foregroundColor: T3Colors.uiTextSecondary,
            dynamicTypeSize: .large
        )

        #expect(
            String(attributed.characters) == "Use bold, emphasis, code, removed, and docs."
        )

        let code = try #require(run("code", in: attributed))
        #expect(attributed[code].backgroundColor == Color(uiColor: T3Colors.uiSurfaceRaised))

        let removed = try #require(run("removed", in: attributed))
        #expect(attributed[removed].strikethroughStyle == .single)

        let bold = try #require(run("bold", in: attributed))
        #expect(attributed[bold].foregroundColor == Color(uiColor: T3Colors.uiTextSecondary))

        let docs = try #require(run("docs", in: attributed))
        #expect(attributed[docs].link == URL(string: "https://example.com"))
        // Links take the accent colour rather than the caller's foreground.
        #expect(attributed[docs].foregroundColor == Color(uiColor: T3Colors.uiAccent))
    }

    /// `Text` renders `inlinePresentationIntent` only against fonts it owns, so
    /// each run's font is resolved up front. That resolution is the part that
    /// broke bold, and the only part still inspectable once it reaches SwiftUI.
    @Test @MainActor
    func inlineIntentsResolveToTraitedFonts() {
        let bold = MarkdownSelectableTextAttributes.font(
            for: .body, intent: .stronglyEmphasized, dynamicTypeSize: .large
        )
        let italic = MarkdownSelectableTextAttributes.font(
            for: .body, intent: .emphasized, dynamicTypeSize: .large
        )
        let code = MarkdownSelectableTextAttributes.font(
            for: .body, intent: .code, dynamicTypeSize: .large
        )
        let plain = MarkdownSelectableTextAttributes.font(
            for: .body, intent: nil, dynamicTypeSize: .large
        )

        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(!plain.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test @MainActor
    func inlineFontsHonorDynamicTypeSize() {
        let small = MarkdownSelectableTextAttributes.font(
            for: .body, intent: nil, dynamicTypeSize: .small
        )
        let accessibility = MarkdownSelectableTextAttributes.font(
            for: .body, intent: nil, dynamicTypeSize: .accessibility1
        )

        #expect(accessibility.pointSize > small.pointSize)
    }

    @Test @MainActor
    func codeBlocksReuseInlineRendering() throws {
        let literalCode = "x = arr[i](fn)\na **b** c\nprintf(\\\"a\\\\tb\\\");"
        let cache = MarkdownRenderCache()
        let first = try #require(
            cache.documentImmediately(
                for: MarkdownContentRevision("```swift\n\(literalCode)\n```")
            )
        )
        let second = try #require(
            cache.documentImmediately(
                for: MarkdownContentRevision("Before\n\n```swift\n\(literalCode)\n```")
            )
        )

        guard case let .codeBlock(_, firstCode, firstInline) = first.blocks.first,
            case let .codeBlock(_, secondCode, secondInline) = second.blocks.last
        else {
            Issue.record("Expected rendered code blocks")
            return
        }

        #expect(firstCode == literalCode)
        #expect(secondCode == firstCode)
        #expect(firstInline === secondInline)
        #expect(firstInline.style == .code)

        // Code is rendered verbatim: no inline Markdown is applied inside it.
        let attributed = MarkdownSelectableTextAttributes.attributedText(
            from: firstInline,
            foregroundColor: T3Colors.uiTextPrimary,
            dynamicTypeSize: .large
        )
        #expect(String(attributed.characters) == firstCode)
    }

    private func run(
        _ text: String,
        in attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        attributed.runs
            .first { String(attributed[$0.range].characters) == text }?
            .range
    }


}

@Suite("Chat Markdown segments")
struct MarkdownSegmentTests {
    /// The transcript renders one cell per segment, so a segment parsed alone
    /// has to produce exactly the blocks it contributed to the whole document.
    /// Anything else means a message renders differently once it is split.
    private func expectSegmentsReproduceDocument(
        _ source: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let whole = MarkdownDocument(parsing: source).blocks
        let rejoined = MarkdownDocument.segments(parsing: source)
            .flatMap { MarkdownDocument(parsing: $0).blocks }
        #expect(rejoined == whole, sourceLocation: sourceLocation)
    }

    @Test
    func paragraphsSplitIntoOneSegmentEach() {
        let segments = MarkdownDocument.segments(parsing: "First para.\n\nSecond para.")

        #expect(segments == ["First para.", "Second para."])
    }

    @Test
    func fencedCodeStaysWhole() {
        let source = "Before.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter."
        let segments = MarkdownDocument.segments(parsing: source)

        #expect(segments.count == 3)
        #expect(segments[1] == "```swift\nlet a = 1\n\nlet b = 2\n```")
        expectSegmentsReproduceDocument(source)
    }

    @Test
    func listsSurviveBlankLinesBetweenItems() {
        let source = "- one\n\n- two\n\n- three"
        let segments = MarkdownDocument.segments(parsing: source)

        #expect(segments.count == 1)
        expectSegmentsReproduceDocument(source)
    }

    @Test
    func blockquotesTablesAndHeadingsRoundTrip() {
        expectSegmentsReproduceDocument(
            """
            # Heading

            > quoted line
            > and another

            | a | b |
            | --- | --- |
            | 1 | 2 |

            Trailing paragraph.
            """
        )
    }

    @Test
    func setextHeadingsAndThematicBreaksRoundTrip() {
        expectSegmentsReproduceDocument(
            """
            Title
            =====

            ---

            Body text.
            """
        )
    }

    @Test
    func mixedMessageRoundTrips() {
        expectSegmentsReproduceDocument(
            """
            Here is **bold** prose with `code`.

            1. first
            2. second

            ```
            plain fence
            ```

            ![alt](https://example.com/a.png)

            Closing words.
            """
        )
    }

    @Test
    func emptyAndBlankSourcesProduceNoSegments() {
        #expect(MarkdownDocument.segments(parsing: "").isEmpty)
        #expect(MarkdownDocument.segments(parsing: "\n\n   \n").isEmpty)
    }
}
