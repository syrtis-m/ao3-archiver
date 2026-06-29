import Testing
import Foundation
import ZIPFoundation
@testable import AO3Kit

/// Pure title-building edges + the load-bearing round-trip: a rewritten EPUB must still open
/// in our own parser with the new title and an unchanged spine.
struct KindleExportTests {
    @Test func abbreviatesWordCounts() {
        #expect(KindleExport.abbreviateWords(nil) == nil)
        #expect(KindleExport.abbreviateWords(0) == nil)
        #expect(KindleExport.abbreviateWords(999) == "<1k words")
        #expect(KindleExport.abbreviateWords(1_000) == "1k words")
        #expect(KindleExport.abbreviateWords(10_000) == "10k words")
        #expect(KindleExport.abbreviateWords(1_500_000) == "1.5M words")
        #expect(KindleExport.abbreviateWords(2_000_000) == "2M words")
    }

    @Test func buildsSuffixWithFandomAndWords() {
        #expect(KindleExport.titleSuffix(fandoms: ["Harry Potter - J. K. Rowling", "Cyberpunk 2077"],
                                         wordCount: 10_000) == "(Harry Potter/Cyberpunk 2077, 10k words)")
    }

    @Test func suffixHandlesEmptyAndCaps() {
        #expect(KindleExport.titleSuffix(fandoms: [], wordCount: nil) == nil)
        #expect(KindleExport.titleSuffix(fandoms: [], wordCount: 5_000) == "(5k words)")
        #expect(KindleExport.titleSuffix(fandoms: ["A", "B", "C"], wordCount: nil) == "(A/B+)")
    }

    @Test func kindleTitleAppendsAndIsInert() {
        #expect(KindleExport.kindleTitle("My Fic", fandoms: ["Marvel"], wordCount: 3_000)
                == "My Fic (Marvel, 3k words)")
        // nothing to add → unchanged
        #expect(KindleExport.kindleTitle("My Fic", fandoms: [], wordCount: nil) == "My Fic")
    }

    @Test func spliceEscapesAmpersandInTitle() {
        let opf = "<metadata><dc:title>Old</dc:title></metadata>"
        let out = KindleExport.spliceTitle(in: opf, to: "Fic (Steven Universe & Co, 1k words)")
        #expect(out == "<metadata><dc:title>Fic (Steven Universe &amp; Co, 1k words)</dc:title></metadata>")
    }

    @Test func splicePreservesTitleAttributes() {
        let opf = #"<dc:title id="t1">Old</dc:title>"#
        #expect(KindleExport.spliceTitle(in: opf, to: "New") == #"<dc:title id="t1">New</dc:title>"#)
    }

    @Test func chapterTextVariants() {
        #expect(KindleExport.chapterText(have: 5, total: 5) == "5/5 chapters")
        #expect(KindleExport.chapterText(have: 3, total: nil) == "3/? chapters")
        #expect(KindleExport.chapterText(have: 1, total: 1) == "1/1 chapter")
        #expect(KindleExport.chapterText(have: nil, total: 7) == nil)
    }

    @Test func infoPageIsWellFormedAndCarriesFields() throws {
        let w = KindleExport.WorkInfo(
            title: "Steven & Co", author: "Auth",
            fandoms: ["Marvel - Comics"], relationships: ["A/B"],
            rating: "Explicit", warnings: ["No Archive Warnings"], category: "M/M",
            wordCount: 12_345, chaptersHave: 5, chaptersTotal: 5, isComplete: true,
            updated: "13 Jun 2026", kudos: 1_234, hits: 56_789)
        let html = KindleExport.infoPageXHTML(for: w)
        // Parses as well-formed XML and the `&` in the title is escaped, not raw.
        #expect((try? XMLDocument(xmlString: html)) != nil)
        #expect(html.contains("Steven &amp; Co"))
        #expect(!html.contains("Steven & Co"))
        #expect(html.contains("Explicit"))
        #expect(html.contains("12,345 words"))
        #expect(html.contains("5/5 chapters"))
        #expect(html.contains("Complete"))
    }

    /// The discriminating check: build a Kindle EPUB from a real synthetic file, then reopen it
    /// with our own parser. Catches string-splice corruption and ZIP surgery breaking the archive.
    @Test func kindleEpubReopensWithInfoPageAndBadge() throws {
        let src = try SyntheticEpub.make(flavour: .ncx)
        let spineBefore = try EpubDocument(url: src).spine.count

        let out = try KindleExport.makeKindleEPUB(
            source: src,
            work: .init(title: "Synthetic Work", author: "Auth",
                        fandoms: ["Harry Potter - J. K. Rowling"], wordCount: 10_000))
        defer { try? FileManager.default.removeItem(at: out) }

        let doc = try EpubDocument(url: out)
        #expect(doc.metadata.title == "Synthetic Work (Harry Potter, 10k words)")
        #expect(doc.spine.count == spineBefore + 1)            // info page added
        #expect(doc.spine.first?.path.hasSuffix(KindleExport.infoPageFilename) == true)  // …and first
        #expect(doc.sectionTitles.contains("About this work"))  // …and in the TOC (so Kindle won't skip it)

        // The written page entry must actually be present + well-formed in the rebuilt zip
        // (spine *referencing* it isn't proof the bytes landed).
        let archive = try Archive(url: out, accessMode: .read)
        let pagePath = try #require(doc.spine.first?.path)   // resolved zip path (may be under OEBPS/)
        let page = try #require(archive[pagePath])
        var bytes = Data(); _ = try archive.extract(page) { bytes.append($0) }
        let html = try #require(String(data: bytes, encoding: .utf8))
        #expect((try? XMLDocument(xmlString: html)) != nil)
        #expect(html.contains("Synthetic Work"))
    }

    @Test func coverRendersAsJPEG() throws {
        let data = try #require(KindleCover.renderJPEG(
            for: .init(title: "A Fic", author: "Auth", fandoms: ["Marvel"], wordCount: 10_000, isComplete: true)))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))   // JPEG SOI marker
        #expect(data.count > 1_000)
    }

    @Test func kindleEpubGetsCoverRegisteredAndExtractable() throws {
        let src = try SyntheticEpub.makeAO3Like()   // root-OPF, no existing cover (like real AO3)
        let out = try KindleExport.makeKindleEPUB(
            source: src, work: .init(title: "The Work Title", author: "A", fandoms: ["Marvel"], wordCount: 2_000))
        defer { try? FileManager.default.removeItem(at: out) }

        let archive = try Archive(url: out, accessMode: .read)
        let opfEntry = try #require(archive["content.opf"])
        var opfBytes = Data(); _ = try archive.extract(opfEntry) { opfBytes.append($0) }
        let opf = try #require(String(data: opfBytes, encoding: .utf8))
        #expect(opf.contains("name=\"cover\""))                       // the thumbnail hint
        #expect(opf.contains(KindleExport.coverFilename))
        let cover = try #require(archive[KindleExport.coverFilename])
        #expect(cover.uncompressedSize > 1_000)                       // the image bytes landed
    }

    @Test func badgeCanBeDisabled() throws {
        let src = try SyntheticEpub.makeAO3Like()
        let out = try KindleExport.makeKindleEPUB(
            source: src, work: .init(title: "The Work Title", author: "A", fandoms: ["Marvel"]),
            addTitleBadge: false)
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(try EpubDocument(url: out).metadata.title == "The Work Title")
    }

    /// mimetype must stay the first entry and stored (uncompressed) after the OPF surgery.
    @Test func buildKeepsMimetypeFirstAndStored() throws {
        let src = try SyntheticEpub.makeAO3Like()
        let out = try KindleExport.makeKindleEPUB(
            source: src, work: .init(title: "The Work Title", author: "A",
                                     fandoms: ["Marvel"], wordCount: 2_000))
        defer { try? FileManager.default.removeItem(at: out) }

        let archive = try Archive(url: out, accessMode: .read)
        let first = archive.makeIterator().next()
        #expect(first?.path == "mimetype")
        #expect(first?.compressedSize == first?.uncompressedSize)  // stored, not deflated
    }
}
