import Foundation
import AO3Kit

/// Reader scenarios shared by both runners (see `EngineScenarios`). Takes the EPUB to use,
/// since each runner has its own synthetic-EPUB builder.
@MainActor
public enum ReaderScenarios {
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
