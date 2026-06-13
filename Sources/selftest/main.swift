import Foundation
import AO3Kit

// Headless verification of BlurbParser / WorkDownloader against the real captured
// fixture. Runs anywhere Swift builds (no XCTest/Testing dependency). Exits non-zero on
// the first failure so it's CI-friendly.

var failures = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("  ✓ \(name)") }
    else { print("  ✗ \(name)"); failures += 1 }
}

// Locate the fixture relative to this source file, so CWD doesn't matter.
let thisFile = URL(fileURLWithPath: #filePath)
let repoRoot = thisFile.deletingLastPathComponent()   // Sources/selftest
    .deletingLastPathComponent()                      // Sources
    .deletingLastPathComponent()                      // repo root
let fixtureURL = repoRoot
    .appendingPathComponent("Tests/AO3KitTests/Fixtures/works_listing.html")

guard let html = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("could not read fixture at \(fixtureURL.path)\n".utf8))
    exit(3)
}

do {
    let blurbs = try BlurbParser.parseListing(html: html)

    print("BlurbParser — listing")
    check("parses 20 cards", blurbs.count == 20)
    check("every card has id/title/author",
          blurbs.allSatisfy { $0.workID > 0 && !$0.title.isEmpty && !$0.author.isEmpty })

    let b = blurbs[0]
    print("BlurbParser — first card fields")
    check("workID == 85487886", b.workID == 85487886)
    check("title", b.title == "Sarcasm and Sanctuary")
    check("author", b.author == "haleinedelail")
    check("authorURL", b.authorURL == "/users/haleinedelail/pseuds/haleinedelail")
    check("fandoms", b.fandoms == ["Good Omens (TV)"])
    check("rating == Explicit", b.rating == "Explicit")
    check("category == M/M", b.category == "M/M")
    check("isComplete == false (WIP)", b.isComplete == false)
    check("language == English", b.language == "English")
    check("wordCount == 12328", b.wordCount == 12328)
    check("chaptersHave == 4", b.chaptersHave == 4)
    check("chaptersTotal == nil (?)", b.chaptersTotal == nil)
    check("comments == 5", b.comments == 5)
    check("kudos == 18", b.kudos == 18)
    check("bookmarksCount == 2", b.bookmarksCount == 2)
    check("hits == 198", b.hits == 198)
    check("dateText", b.dateText == "13 Jun 2026")
    check("updatedAt == 1781388945", b.updatedAt == 1781388945)
    check("warnings include CNTW", b.warnings.contains("Creator Chose Not To Use Archive Warnings"))
    check("freeforms include Hinduism", b.freeforms.contains("Hinduism"))
    check("relationships count == 2", b.relationships.count == 2)
    check("summary present", b.summary?.contains("Prof. Anthony Crowley") == true)

    print("ArchivePaths")
    check("sanitize illegal chars", ArchivePaths.sanitize("A/B: C?") == "A B C")
    check("sanitize empty → untitled", ArchivePaths.sanitize("   ") == "untitled")

    // Bookmarks page uses li.bookmark.blurb.group containers (+ a bookmarker section).
    // Validates that the same parser handles the real bookmarks markup.
    let bookmarksURL = repoRoot.appendingPathComponent("Tests/AO3KitTests/Fixtures/bookmarks_page.html")
    if let bmHTML = try? String(contentsOf: bookmarksURL, encoding: .utf8) {
        let bm = try BlurbParser.parseListing(html: bmHTML)
        // 20 bookmark cards = 19 AO3 works + 1 external-work bookmark. All are recorded;
        // kind distinguishes them and only .work is downloadable.
        let bmWorks = bm.filter { $0.kind == .work }
        let bmExternal = bm.filter { $0.kind == .external }
        print("BlurbParser — bookmarks page")
        check("parses all 20 bookmark cards", bm.count == 20)
        check("19 are AO3 works", bmWorks.count == 19)
        check("1 is an external work", bmExternal.count == 1)
        check("external card has /external_works/ sourcePath",
              bmExternal.first?.sourcePath.contains("/external_works/") == true)
        check("external card author (plain text) == agrippa", bmExternal.first?.author == "agrippa")
        check("external card has no EPUB-relevant stats", bmExternal.first?.wordCount == nil)
        check("first work bookmark workID == 1413325", bmWorks.first?.workID == 1413325)
        check("first work bookmark title", bmWorks.first?.title == "circus girl without a safety net")
        check("all work bookmarks have stats (wordCount)", bmWorks.allSatisfy { $0.wordCount != nil })
    }

    print("WorkDownloader")
    let menu = """
    <li class="download"><ul>
      <li><a href="/downloads/9/T.azw3?updated_at=1">AZW3</a></li>
      <li><a href="/downloads/9/T.epub?updated_at=1">EPUB</a></li>
    </ul></li>
    """
    check("extracts epub href", try WorkDownloader.epubHref(fromWorkHTML: menu) == "/downloads/9/T.epub?updated_at=1")
    check("nil when no menu", try WorkDownloader.epubHref(fromWorkHTML: "<p>locked</p>") == nil)
    check("epub magic true", WorkDownloader.looksLikeEPUB(Data([0x50, 0x4B, 0x03, 0x04])))
    check("epub magic false", !WorkDownloader.looksLikeEPUB(Data("<htm".utf8)))
} catch {
    FileHandle.standardError.write(Data("threw: \(error)\n".utf8))
    exit(1)
}

print("")
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
