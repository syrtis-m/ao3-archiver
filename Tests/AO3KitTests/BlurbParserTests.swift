import Testing
import Foundation
@testable import AO3Kit

/// Tests run against real AO3 HTML captured into Fixtures/works_listing.html, so they
/// pin the parser to the actual markup rather than to assumptions.
@Suite struct BlurbParserTests {

    func fixtureHTML() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "works_listing", withExtension: "html", subdirectory: "Fixtures"),
            "fixture not found in test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesAllCardsOnPage() throws {
        let blurbs = try BlurbParser.parseListing(html: fixtureHTML())
        #expect(blurbs.count == 20)   // AO3 renders 20 works per listing page
    }

    @Test func firstCardFieldsMatchSource() throws {
        let b = try #require(BlurbParser.parseListing(html: fixtureHTML()).first)

        #expect(b.workID == 85487886)
        #expect(b.title == "Sarcasm and Sanctuary")
        #expect(b.author == "haleinedelail")
        #expect(b.authorURL == "/users/haleinedelail/pseuds/haleinedelail")
        #expect(b.fandoms == ["Good Omens (TV)"])
        #expect(b.rating == "Explicit")
        #expect(b.category == "M/M")
        #expect(b.isComplete == false)                  // "Work in Progress" symbol
        #expect(b.language == "English")
        #expect(b.wordCount == 12328)                   // from "12,328"
        #expect(b.chaptersHave == 4)
        #expect(b.chaptersTotal == nil)                 // "4/?" ⇒ unknown total
        #expect(b.comments == 5)
        #expect(b.kudos == 18)
        #expect(b.bookmarksCount == 2)
        #expect(b.hits == 198)
        #expect(b.dateText == "13 Jun 2026")
        #expect(b.updatedAt == 1781388945)              // from "<!-- updated_at=… -->"

        #expect(b.warnings.contains("Creator Chose Not To Use Archive Warnings"))
        #expect(b.freeforms.contains("Hinduism"))
        #expect(b.characters.contains("New Universe Anthony Crowley (Good Omens)"))
        #expect(b.relationships.count == 2)
        #expect(b.summary?.contains("Prof. Anthony Crowley") == true)
    }

    @Test func parsesRealBookmarksPage() throws {
        let url = try #require(
            Bundle.module.url(forResource: "bookmarks_page", withExtension: "html", subdirectory: "Fixtures"))
        let blurbs = try BlurbParser.parseListing(html: String(contentsOf: url, encoding: .utf8))
        // 20 bookmark cards = 19 AO3 works + 1 external-work bookmark. All recorded;
        // `kind` distinguishes them so external bookmarks are filterable, not lost.
        #expect(blurbs.count == 20)
        #expect(blurbs.filter { $0.kind == .work }.count == 19)
        let external = blurbs.filter { $0.kind == .external }
        #expect(external.count == 1)
        #expect(external.first?.author == "agrippa")             // plain-text author
        #expect(external.first?.sourcePath.contains("/external_works/") == true)
        #expect(external.first?.wordCount == nil)
        #expect(blurbs.first?.workID == 1413325)
        #expect(blurbs.first?.title == "circus girl without a safety net")
    }

    @Test func everyCardHasIDTitleAuthor() throws {
        let blurbs = try BlurbParser.parseListing(html: fixtureHTML())
        for b in blurbs {
            #expect(b.workID > 0)
            #expect(!b.title.isEmpty)
            #expect(!b.author.isEmpty)
        }
    }

    @Test func intParsingStripsCommas() {
        #expect(BlurbParser.parseInt("1,234,567") == 1234567)
        #expect(BlurbParser.parseInt("18") == 18)
        #expect(BlurbParser.parseInt("—") == nil)
    }

    @Test func workIDFromHrefVariants() {
        #expect(BlurbParser.workID(fromWorkHref: "/works/85487886") == 85487886)
        #expect(BlurbParser.workID(fromWorkHref: "/works/123/chapters/456") == 123)
        #expect(BlurbParser.workID(fromWorkHref: "/users/foo") == nil)
    }

    @Test func sanitizeFilename() {
        #expect(ArchivePaths.sanitize("A/B: C?") == "A B C")
        #expect(ArchivePaths.sanitize("   ") == "untitled")
    }
}

/// Verifies EPUB download-link extraction against a faithful copy of AO3's download menu.
@Suite struct WorkDownloaderTests {
    @Test func extractsEPUBHref() throws {
        let html = """
        <ul class="actions">
          <li class="download">
            <a>Download</a>
            <ul class="menu">
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.azw3?updated_at=1781388945">AZW3</a></li>
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.epub?updated_at=1781388945">EPUB</a></li>
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.pdf?updated_at=1781388945">PDF</a></li>
            </ul>
          </li>
        </ul>
        """
        let href = try WorkDownloader.epubHref(fromWorkHTML: html)
        #expect(href == "/downloads/85487886/Sarcasm_and_Sanctuary.epub?updated_at=1781388945")
    }

    @Test func noDownloadMenuReturnsNil() throws {
        #expect(try WorkDownloader.epubHref(fromWorkHTML: "<html><body>locked</body></html>") == nil)
    }

    @Test func epubMagicDetection() {
        #expect(WorkDownloader.looksLikeEPUB(Data([0x50, 0x4B, 0x03, 0x04, 0x00])))
        #expect(!WorkDownloader.looksLikeEPUB(Data("<html".utf8)))
        #expect(!WorkDownloader.looksLikeEPUB(Data()))
    }
}
