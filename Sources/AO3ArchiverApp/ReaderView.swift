import SwiftUI
import WebKit
import AO3Kit

/// The in-app EPUB reader: a `WKWebView` rendering a **generated `text/html` document** (the
/// current chapter, or the whole work in scroll mode) wrapped in glass chrome (title/progress,
/// chapter nav, TOC + typography popovers). All logic — section navigation, progress, the
/// generated HTML + CSS — is `ReaderModel` / `ReaderSession` / `ReaderSettings` in AO3Kit.
/// Compile-verified; visuals confirmed in-app.
struct ReaderView: View {
    let epubURL: URL
    let workID: Int
    let workTitle: String
    let store: Store?

    @State private var model: ReaderModel?
    @State private var loadError: String?
    @State private var target: ReaderModel.RenderTarget?
    @State private var showTOC = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else if let loadError {
                errorState(loadError)
            } else {
                ProgressView("Opening…").controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .task { await start() }
        .onDisappear { model?.cleanup() }
    }

    // MARK: - Loaded reader

    @ViewBuilder
    private func content(_ model: ReaderModel) -> some View {
        VStack(spacing: 0) {
            topBar(model)
            if !model.isScroll {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear).tint(.accentColor)
            }
            Divider().opacity(0.3)
            if let target {
                EpubWebView(target: target) { model.recordVisibleSection($0) }
                    .ignoresSafeArea(edges: .bottom)
            } else {
                // Scroll mode sanitizes the whole work off-main before its first render.
                ProgressView("Preparing…").controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Rebuild when mode, current unit, or styling changes (settings, chapter nav).
        .onChange(of: model.renderKey) { rebuild(model) }
    }

    private func topBar(_ model: ReaderModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentTitle).font(.headline).lineLimit(1)
                if model.isScroll {
                    if let a = model.author { Text(a).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("\(model.currentIndex + 1) of \(model.unitCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)

            if !model.isScroll {
                Button { model.goPrevious() } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!model.canGoPrevious)
                Button { model.goNext() } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!model.canGoNext)
            }

            Button { showTOC.toggle() } label: { Image(systemName: "list.bullet") }
                .keyboardShortcut("t", modifiers: .command)
                .popover(isPresented: $showTOC, arrowEdge: .bottom) { tocPopover(model) }

            Button { showSettings.toggle() } label: { Image(systemName: "textformat.size") }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover(model) }
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Popovers

    private func tocPopover(_ model: ReaderModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.sectionTitles.enumerated()), id: \.offset) { idx, title in
                    Button {
                        model.jump(toSection: idx); rebuild(model); showTOC = false
                    } label: {
                        HStack {
                            Text(title).lineLimit(1)
                            Spacer()
                            if idx == model.currentIndex {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                }
            }
            .padding(8)
        }
        .frame(width: 340, height: 400)
    }

    private func settingsPopover(_ model: ReaderModel) -> some View {
        Form {
            Picker("Mode", selection: layoutBinding(model)) {
                ForEach(ReaderSettings.Layout.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: themeBinding(model)) {
                ForEach(ReaderSettings.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Stepper("Text size", value: fontScaleBinding(model),
                    in: ReaderSettings.fontScaleRange, step: 0.1)
            Stepper("Line spacing", value: lineSpacingBinding(model),
                    in: ReaderSettings.lineSpacingRange, step: 0.1)

            Picker("Font", selection: fontBinding(model)) {
                ForEach(["Georgia", "Iowan Old Style", "Palatino", "Helvetica Neue", "Menlo"], id: \.self) {
                    Text($0).tag($0)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // Bindings that write through to the model's settings (which persists + triggers rebuild).
    private func themeBinding(_ m: ReaderModel) -> Binding<ReaderSettings.Theme> {
        Binding(get: { m.settings.theme }, set: { m.settings.theme = $0 })
    }
    private func layoutBinding(_ m: ReaderModel) -> Binding<ReaderSettings.Layout> {
        Binding(get: { m.settings.layout }, set: { m.settings.layout = $0 })
    }
    private func fontScaleBinding(_ m: ReaderModel) -> Binding<Double> {
        Binding(get: { m.settings.fontScale }, set: { m.settings.fontScale = $0 })
    }
    private func lineSpacingBinding(_ m: ReaderModel) -> Binding<Double> {
        Binding(get: { m.settings.lineSpacing }, set: { m.settings.lineSpacing = $0 })
    }
    private func fontBinding(_ m: ReaderModel) -> Binding<String> {
        Binding(get: { m.settings.fontFamily }, set: { m.settings.fontFamily = $0 })
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open this work", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([epubURL]) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func start() async {
        guard model == nil, loadError == nil else { return }
        do {
            let m = try ReaderModel(epubURL: epubURL, workID: workID,
                                    workTitle: workTitle, store: store)
            model = m
            await buildTarget(m)
        } catch {
            loadError = String(describing: error)
        }
    }

    private func rebuild(_ m: ReaderModel) { Task { await buildTarget(m) } }

    /// Prepare scroll-mode bodies off-main (no-op in chapter mode / once prepared), then build.
    private func buildTarget(_ m: ReaderModel) async {
        await m.prepareScrollBodiesIfNeeded()
        target = m.renderTarget()
    }
}

/// `WKWebView` that renders the reader's generated `text/html` document from disk.
/// **Security:** the no-remote-requests invariant is enforced upstream — `EpubSanitizer`
/// strips remote refs/scripts/handlers from every body the document is built from, so the
/// rendered page references nothing off-disk. This delegate additionally cancels any
/// non-`file:` *navigation* as defense in depth. JavaScript is on only to scroll to a section
/// anchor in scroll mode (operating on already-clean, locally-generated content).
struct EpubWebView: NSViewRepresentable {
    let target: ReaderModel.RenderTarget
    /// Called (main thread, debounced) with the topmost-visible section index as the user scrolls.
    var onVisibleSection: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onVisibleSection: onVisibleSection) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // The scroll reporter posts here; removed in dismantleNSView to avoid a retain cycle
        // (config → userContentController → coordinator → webView).
        config.userContentController.add(context.coordinator, name: "reader")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.apply(target, to: webView, force: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onVisibleSection = onVisibleSection
        context.coordinator.apply(target, to: webView, force: false)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onVisibleSection: (Int) -> Void
        private var loadedVersion: String?
        private var appliedAnchor: String?
        private var pendingAnchor: String?

        init(onVisibleSection: @escaping (Int) -> Void) { self.onVisibleSection = onVisibleSection }

        func apply(_ target: ReaderModel.RenderTarget, to webView: WKWebView, force: Bool) {
            // Reload on a content change (version), not a path change — the file path is reused
            // across renders, so the document is overwritten in place.
            if force || loadedVersion != target.version {
                loadedVersion = target.version
                appliedAnchor = target.anchor
                pendingAnchor = target.anchor
                webView.loadFileURL(target.file, allowingReadAccessTo: target.readAccess)
            } else if target.anchor != appliedAnchor {
                // Anchor *changed* (a TOC jump) — scroll once. Crucially we do NOT re-scroll on
                // every re-render, or we'd yank the reader back while they scroll.
                appliedAnchor = target.anchor
                if let anchor = target.anchor { scroll(to: anchor, in: webView) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let anchor = pendingAnchor { scroll(to: anchor, in: webView); pendingAnchor = nil }
        }

        // Scroll reporter → persist the section actually being read (main thread already).
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let i = body["i"] as? Int else { return }
            onVisibleSection(i)
        }

        private func scroll(to anchor: String, in webView: WKWebView) {
            let safe = anchor.replacingOccurrences(of: "'", with: "")
            webView.evaluateJavaScript("document.getElementById('\(safe)')?.scrollIntoView();", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.isFileURL {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)   // never reach off-disk
            }
        }
    }
}
