import Foundation
import AO3Kit

/// Reader scenarios shared by both runners (see `EngineScenarios`). Takes the EPUB to use,
/// since each runner has its own synthetic-EPUB builder.
@MainActor
public enum ReaderScenarios {
    /// The off-main gallery reload lands the store's items; a synchronous load issued while an
    /// async reload is in flight wins (the stale result is dropped).
    public static func galleryReload() async throws -> [EngineScenarios.Check] {
        let store = try Store(inMemory: true)
        for id in 1...3 {
            try store.upsertWorkAndBookmark(WorkBlurb(sourcePath: "/works/\(id)", workID: id, title: "W\(id)",
                                                      author: "a", bookmarkID: id))
        }
        let vm = GalleryViewModel()
        await vm.reload(from: store)
        let first = vm.allItems.count
        let pending = Task { await vm.reload(from: store) }   // starts, then is superseded
        try store.upsertWorkAndBookmark(WorkBlurb(sourcePath: "/works/4", workID: 4, title: "W4",
                                                  author: "a", bookmarkID: 4))
        vm.load(from: store)
        await pending.value
        return [
            ("async reload loads the store", first == 3),
            ("newer synchronous load isn't overwritten by an older fetch", vm.allItems.count == 4),
        ]
    }

    /// Resources extract off-main and the reader renders; if the EPUB vanishes before
    /// extraction, the reader reports why instead of staying blank forever.
    public static func extraction(epubURL: URL) async throws -> [EngineScenarios.Check] {
        let ok = try ReaderModel(epubURL: epubURL, workID: 1, workTitle: "T", store: nil)
        let preparingBefore = ok.isPreparing
        async let a: Void = ok.prepareExtractionIfNeeded()
        async let b: Void = ok.prepareExtractionIfNeeded()   // concurrent: must share one job
        _ = await (a, b)
        await ok.prepareScrollBodiesIfNeeded()   // as the view does (a no-op in chapter mode)
        let target = ok.renderTarget()
        let why = ok.renderError ?? "scroll=\(ok.isScroll) preparing=\(ok.isPreparing)"
        ok.cleanup()

        // A copy we can delete after the model has opened it.
        let doomed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doomed-\(UUID()).epub")
        try FileManager.default.copyItem(at: epubURL, to: doomed)
        let broken = try ReaderModel(epubURL: doomed, workID: 2, workTitle: "T", store: nil)
        try FileManager.default.removeItem(at: doomed)
        await broken.prepareExtractionIfNeeded()

        return [
            ("preparing until extracted", preparingBefore),
            ("renders after off-main extraction (\(why))", target != nil && ok.renderError == nil),
            ("extraction failure surfaces renderError", broken.renderError != nil),
            ("…and yields no target rather than a blank page", broken.renderTarget() == nil),
        ]
    }
}
