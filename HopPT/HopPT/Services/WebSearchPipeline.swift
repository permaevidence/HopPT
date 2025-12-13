import Foundation
import CoreData
import WebKit
import PDFKit
import NaturalLanguage


// MARK: - Scraping Mode Configuration
enum ScrapingMode: String, CaseIterable, Identifiable, Hashable {
    case localWebKit = "localWebKit"
    case serperAPI   = "serperAPI"  // NOTE: keep rawValue for persistence

    var id: String { rawValue }
    var label: String {
        switch self {
        case .localWebKit: return "Local (WebKit)"
        case .serperAPI:   return "Jina Reader (API)"   // CHANGED label
        }
    }
}

// MARK: - AsyncSemaphore for concurrency control
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = max(1, permits) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func withPermit<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

// MARK: - Debug logger (ordered prints across tasks)
actor DebugLog {
    static let shared = DebugLog()
    private let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "HH:mm:ss.SSS"
        return d
    }()
    private func ts() -> String { df.string(from: Date()) }

    func line(_ tag: String, _ message: String) {
        print("[\(ts())] [\(tag)] \(message)")
    }

    func error(_ tag: String, _ message: String, err: Error? = nil) {
        if let err { print("[\(ts())] [\(tag)] ERROR: \(message) :: \(err)") }
        else { print("[\(ts())] [\(tag)] ERROR: \(message)") }
    }

    /// Prints the *full* scraped body (can be HUGE).
    func scrapeDump(url: String, content: String?) {
        let len = content?.count ?? 0
        print("----- BEGIN SCRAPE \(url) (\(len) chars) -----")
        if let c = content, !c.isEmpty { print(c) } else { print("<empty>") }
        print("----- END SCRAPE \(url) -----")
    }
    func jsonPretty<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { return s }
        return "<encode-failed>"
    }

    /// Dumps *only* RAG chunks (the excerpts your LLM will use), plus the per-URL focus query.
    func ragChunksDump<T: Encodable>(url: String, title: String?, ragQuery: String?, chunks: [T]?) {
        print("===== BEGIN RAG CHUNKS \(url) =====")
        if let title, !title.isEmpty { print("Title: \(title)") }
        print("Focus/RAG query: \(ragQuery ?? "-")")
        if let chunks, !chunks.isEmpty {
            print(jsonPretty(chunks))
        } else {
            print("<no ragChunks>")
        }
        print("===== END RAG CHUNKS \(url) =====")
    }
}

// MARK: - CMP Blocker for cookie consent popups
actor CMPBlocker {
    static let shared = CMPBlocker()
    private var ruleList: WKContentRuleList?

    private let rules = #"""
    [
      { "trigger": { "url-filter": "https?://([^/]*\\.)?cookielaw\\.org/.*" },            "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://consent\\.cookiebot\\.com/.*" },             "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?cookiebot\\.com/.*" },            "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?quantcast\\.com/.*" },            "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?consensu\\.org/.*" },             "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://consent\\.truste\\.com/.*" },                "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?trustarc\\.com/.*" },             "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?usercentrics\\.eu/.*" },          "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?privacy-mgmt\\.com/.*" },         "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?didomi\\.io/.*" },                "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://fundingchoicesmessages\\.google\\.com/.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "https?://([^/]*\\.)?cookieyes\\.com/.*" },            "action": { "type": "block" } },

      { "trigger": { "url-filter": ".*" },
        "action": { "type": "css-display-none",
          "selector": "#onetrust-banner-sdk, #onetrust-consent-sdk, .ot-sdk-container, .qc-cmp2-container, \
                       #CybotCookiebotDialog, .fc-consent-root, .didomi-popup, .sp-message-container, \
                       .sp-privacy-manager, .truste_overlay, .truste-box, .cookie-consent, .cookie-banner, \
                       .cc-window, [aria-modal='true'][role='dialog']"
        }
      }
    ]
    """#

    func ruleListForUse() async throws -> WKContentRuleList {
        if let r = ruleList { return r }
        return try await withCheckedThrowingContinuation { cont in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "cmp-block",
                encodedContentRuleList: rules
            ) { list, error in
                if let error { cont.resume(throwing: error); return }
                guard let list else {
                    cont.resume(throwing: NSError(
                        domain: "CMPBlocker", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to compile content rules"]
                    ))
                    return
                }
                self.ruleList = list
                cont.resume(returning: list)
            }
        }
    }
}

// MARK: - WebKit-based Page Scraper
@MainActor
final class PageToPDFRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var navContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    private static let cookieDefangJS = """
    (() => {
      const css = 
        html, body { overflow: auto !important; height: auto !important; position: static !important; }
        body[style*="overflow: hidden"] { overflow: auto !important; }
        [inert] { pointer-events: auto !important; }
        #onetrust-banner-sdk, #onetrust-consent-sdk, .ot-sdk-container, .qc-cmp2-container,
        #CybotCookiebotDialog, .fc-consent-root, .didomi-popup, .sp-message-container,
        .sp-privacy-manager, .truste_overlay, .truste-box, .cookie-consent, .cookie-banner, .cc-window,
        [aria-modal="true"][role="dialog"] {
          display: none !important; visibility: hidden !important; opacity: 0 !important;
        }
      ;
      const s = document.createElement('style'); s.textContent = css; document.documentElement.appendChild(s);
      const clearLocks = () => {
        document.querySelectorAll('[inert]').forEach(el => el.removeAttribute('inert'));
        document.querySelectorAll('[aria-hidden="true"]').forEach(el => el.removeAttribute('aria-hidden'));
      };
      new MutationObserver(clearLocks).observe(document.documentElement, { attributes: true, subtree: true });
      clearLocks();
    })();
    """
    
    private static let textSafetyCSSJS = """
    (() => {
      const css = 
        * {
          -webkit-hyphens: none !important;
          hyphens: none !important;
          font-variant-ligatures: none !important;
        }
      ;
      const s = document.createElement('style');
      s.textContent = css;
      document.documentElement.appendChild(s);
    })();
    """

    init(configuration: WKWebViewConfiguration) {
        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 1200, height: 10000), configuration: configuration)
        super.init()
        self.webView.navigationDelegate = self
    }

    static func makeConfiguredWebViewConfiguration(userAgent: String? = nil) async throws -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptEnabled = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        cfg.websiteDataStore = .nonPersistent()
        if let ua = userAgent { cfg.applicationNameForUserAgent = ua }

        do {
            let ruleList = try await CMPBlocker.shared.ruleListForUse()
            cfg.userContentController.add(ruleList)
        } catch {
            print("[CMP] Rule compile failed → continuing without blocker: \(error.localizedDescription)")
        }

        let userScript = WKUserScript(source: cookieDefangJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(userScript)

        let noHyphenScript = WKUserScript(source: textSafetyCSSJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(noHyphenScript)
        
        return cfg
    }

    func scrapeURL(_ url: URL,
                   maxWait: TimeInterval = 100,
                   settleSamples: Int = 3,
                   sampleInterval: TimeInterval = 0.8) async throws -> ScrapedDoc {
        // Direct PDF handling
        if url.pathExtension.lowercased() == "pdf" {
            let (data, _) = try await URLSession.shared.data(from: url)
            return extractFromPDFData(data, url: url)
        } else if await looksLikePDFViaHEAD(url) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return extractFromPDFData(data, url: url)
        }

        // Load page with blockers
        try await load(url: url, timeout: maxWait)
        try await waitForStableContent(maxWait: maxWait, settleSamples: settleSamples, sampleInterval: sampleInterval)
        
        // Expand WebView to full content height
        try await expandWebViewToFullHeight()

        // Create PDF from full page
        let pdfData = try await createFullPagePDF()
        return extractFromPDFData(pdfData, url: url, titleFallback: await pageTitle())
    }

    private func expandWebViewToFullHeight() async throws {
        let heightScript = """
        Math.max(
            document.body.scrollHeight,
            document.body.offsetHeight,
            document.documentElement.clientHeight,
            document.documentElement.scrollHeight,
            document.documentElement.offsetHeight
        )
        """
        
        guard let height = try await webView.evaluateJavaScript(heightScript) as? Double else {
            return
        }
        
        let fullHeight = height + 100
        webView.frame = CGRect(x: 0, y: 0, width: 1200, height: fullHeight)
        
        try await Task.sleep(nanoseconds: 500_000_000)
        await triggerLazyLoading()
    }
    
    private func triggerLazyLoading() async {
        do {
            let heightScript = "document.documentElement.scrollHeight"
            guard let totalHeight = try await webView.evaluateJavaScript(heightScript) as? Double else { return }
            
            let scrollStep: Double = 500
            var currentPosition: Double = 0
            
            while currentPosition < totalHeight {
                let scrollScript = "window.scrollTo(0, \(currentPosition))"
                _ = try? await webView.evaluateJavaScript(scrollScript)
                currentPosition += scrollStep
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
            try await Task.sleep(nanoseconds: 300_000_000)
            
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0)")
            try await Task.sleep(nanoseconds: 200_000_000)
            
        } catch {
            print("Error during lazy loading trigger: \(error)")
        }
    }

    private func load(url: URL, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.navContinuation = cont
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            _ = self.webView.load(req)

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let cont = self.navContinuation else { return }
                self.navContinuation = nil
                cont.resume(throwing: URLError(.timedOut))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeoutTask?.cancel()
        timeoutTask = nil
        navContinuation?.resume()
        navContinuation = nil
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        navContinuation?.resume(throwing: error)
        navContinuation = nil
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        navContinuation?.resume(throwing: error)
        navContinuation = nil
    }

    private func waitForStableContent(maxWait: TimeInterval,
                                      settleSamples: Int,
                                      sampleInterval: TimeInterval) async throws {
        let start = Date()
        var lastLen = -1
        var lastHeight = -1
        var stableCount = 0

        while Date().timeIntervalSince(start) < maxWait, stableCount < settleSamples {
            let metrics = try await evaluateMetrics()

            let len = metrics.len
            let height = metrics.height
            let ready = metrics.ready == "complete"

            let lenStable = lastLen > 0 ? abs(Double(len - lastLen)) <= max(1.0, Double(lastLen) * 0.02) : false
            let heightStable = lastHeight > 0 ? abs(Double(height - lastHeight)) <= max(1.0, Double(lastHeight) * 0.02) : false

            if ready && lenStable && heightStable {
                stableCount += 1
            } else {
                stableCount = 0
            }
            lastLen = len
            lastHeight = height

            try await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
        }
    }

    private func evaluateMetrics() async throws -> (ready: String, len: Int, height: Int) {
        let script = """
        (function(){
          const r = document.readyState;
          const b = document.body;
          const len = b ? (b.innerText || "").length : 0;
          const h = Math.max(
            b ? b.scrollHeight : 0,
            b ? b.offsetHeight : 0,
            b ? b.clientHeight : 0,
            document.documentElement.scrollHeight,
            document.documentElement.offsetHeight,
            document.documentElement.clientHeight
          );
          return {ready:r, len:len, height:h};
        })();
        """
        let any = try await webView.evaluateJavaScript(script)
        guard
            let dict = any as? [String: Any],
            let ready = dict["ready"] as? String,
            let len = dict["len"] as? Int,
            let height = dict["height"] as? Int
        else {
            return ("loading", 0, 0)
        }
        return (ready, len, height)
    }

    private func pageTitle() async -> String? {
        (try? await webView.evaluateJavaScript("document.title")) as? String
    }

    private func createFullPagePDF() async throws -> Data {
        try await createPaginatedPDFUsingWebView(webView)
    }
    
    private func createPaginatedPDFUsingWebView(_ wv: WKWebView,
                                                maxPageHeight: CGFloat = 12000,
                                                overlap: CGFloat = 24) async throws -> Data {
        let widthScript = """
        Math.max(
          document.body ? document.body.scrollWidth : 0,
          document.documentElement.clientWidth,
          document.documentElement.scrollWidth,
          document.documentElement.offsetWidth
        )
        """
        let heightScript = """
        Math.max(
          document.body ? document.body.scrollHeight : 0,
          document.documentElement.clientHeight,
          document.documentElement.scrollHeight,
          document.documentElement.offsetHeight
        )
        """

        let contentWidth = CGFloat((try? await wv.evaluateJavaScript(widthScript) as? Double) ?? 1024)
        let contentHeight = CGFloat((try? await wv.evaluateJavaScript(heightScript) as? Double) ?? 2000)

        return try await createPaginatedPDF(for: wv,
                                            contentWidth: contentWidth,
                                            contentHeight: contentHeight,
                                            maxPageHeight: maxPageHeight,
                                            overlap: overlap)
    }

    private func createPaginatedPDF(for wv: WKWebView,
                                    contentWidth: CGFloat,
                                    contentHeight: CGFloat,
                                    maxPageHeight: CGFloat,
                                    overlap: CGFloat) async throws -> Data {
        let pageWidth = contentWidth
        let pageHeight = min(maxPageHeight, contentHeight)

        let master = PDFDocument()
        var pageCounter = 0
        var y: CGFloat = 0

        while y < contentHeight {
            let h = min(pageHeight, contentHeight - y)
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: y, width: pageWidth, height: h)

            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                wv.createPDF(configuration: cfg) { result in
                    switch result {
                    case .success(let data): cont.resume(returning: data)
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }

            if let doc = PDFDocument(data: chunk) {
                for i in 0..<doc.pageCount {
                    if let pg = doc.page(at: i) {
                        master.insert(pg, at: pageCounter)
                        pageCounter += 1
                    }
                }
            }

            y += (pageHeight - overlap)
        }

        guard let combined = master.dataRepresentation() else {
            throw NSError(domain: "PDFCombine",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to combine PDF fragments"])
        }
        return combined
    }

    private func extractFromPDFData(_ data: Data, url: URL, titleFallback: String? = nil) -> ScrapedDoc {
        let pdf = PDFDocument(data: data)
        let text = (pdf?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (pdf?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? titleFallback
        
        // Convert to ScrapedDoc format used by WebSearchPipeline
        return ScrapedDoc(
            url: url.absoluteString,
            source: url.host?.lowercased() ?? "",
            title: title,
            markdown: nil,
            text: text.isEmpty ? nil : text,
            ragChunks: nil,
            ragQuery: nil
        )
    }

    private func looksLikePDFViaHEAD(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse,
               let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               mime.contains("application/pdf") {
                return true
            }
        } catch { }
        return false
    }
}

// MARK: - Local Web Scraper (manages concurrent scraping)
actor LocalWebScraper {
    private let gate = AsyncSemaphore(3) // Max 3 concurrent WKWebViews
    private var cancelled = false

    func cancelAllTasks() async { cancelled = true }
    func getCancelled() -> Bool { cancelled }

    func scrapeURL(_ urlString: String) async throws -> ScrapedDoc {
        if cancelled { throw URLError(.cancelled) }
        guard let url = URL(string: urlString) else {
            return ScrapedDoc(
                url: urlString,
                source: "",
                title: nil,
                markdown: nil,
                text: "Invalid URL",
                ragChunks: nil,
                ragQuery: nil
            )
        }

        return try await gate.withPermit {
            if await self.getCancelled() { throw URLError(.cancelled) }

            let cfg = try await PageToPDFRenderer.makeConfiguredWebViewConfiguration(
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            )
            let renderer = await MainActor.run { PageToPDFRenderer(configuration: cfg) }
            return try await renderer.scrapeURL(url)
        }
    }

    func scrapeURLs(_ urls: [String]) async -> [ScrapedDoc] {
        await withTaskGroup(of: ScrapedDoc.self) { group in
            for u in urls {
                group.addTask { [weak self] in
                    guard let self else {
                        return ScrapedDoc(
                            url: u,
                            source: "",
                            title: nil,
                            markdown: nil,
                            text: "Scraper deallocated",
                            ragChunks: nil,
                            ragQuery: nil
                        )
                    }
                    do {
                        return try await self.scrapeURL(u)
                    } catch {
                        await DebugLog.shared.error("SCRAPER", "Local scrape error for \(u)", err: error)
                        return ScrapedDoc(
                            url: u,
                            source: URL(string: u)?.host?.lowercased() ?? "",
                            title: nil,
                            markdown: nil,
                            text: nil,
                            ragChunks: nil,
                            ragQuery: nil
                        )
                    }
                }
            }
            var out: [ScrapedDoc] = []
            for await r in group { out.append(r) }
            return out
        }
    }
}

enum WebStage: String, Equatable {
    case generatingQueries
    case analyzingResults
    case scraping
}

struct WebStatus: Equatable {
    let stage: WebStage
    let urls: [String]   // ← no default here

    init(stage: WebStage) {
        self.stage = stage
        self.urls = []
    }

    init(scraping urls: [String]) {
        self.stage = .scraping
        self.urls = urls
    }
}

// MARK: - Public pipeline facade
final class WebSearchPipeline {
    
    private let settings: AppSettings
        init(settings: AppSettings) { self.settings = settings }

    
    // Serper endpoints
    private let serperScrapeURL = URL(string: "https://scrape.serper.dev")!
    private let serperSearchURL = URL(string: "https://google.serper.dev/search")!
    private let jinaReaderURL = URL(string: "https://r.jina.ai/")!

    // Safety limits to keep token usage sane
    private let maxOrganicPerQuery = 10
    private let maxTotalResults = 40
    private let maxSnippetChars = 460
    private let maxContextBytes = 200_000  // ~ rough cap before second LLM call
    private let llmRequestTimeout: TimeInterval = 15 * 60   // 15 minutes
    private let serperRequestTimeout: TimeInterval = 60      // fast failure for web search
    
    private let scrapeCache = ScrapeCache()

    
    // SCRAPING MODE TOGGLE - Change this to switch between Serper API and local WebKit scraping
    private var scrapingMode: ScrapingMode = .localWebKit  // <-- CHANGE THIS TO .localWebKit TO USE LOCAL and .serperAPI  for serper SCRAPING
    
    // Local scraper instance
    private let localScraper = LocalWebScraper()
    
    private struct DebugConfig {
        var dumpFullScrapes = false        // print full page bodies (HUGE) — keep this off now
        var logScrapeFailures = true
        var logScrapeSummaries = false
        var dumpAfterRAG = false           // post-RAG *full* body excerpts (leave off)
        var dumpRAGChunksOnly = true       // <— NEW: print only the RAG chunks sent to the LLM
    }
    private var debug = DebugConfig()
    
    private struct JinaReaderReq: Encodable { let url: String }
    
    private struct JinaReaderDirect: Decodable {
            let url: String?
            let title: String?
            let content: String?
            let timestamp: String?
        }
    
    private struct JinaReaderEnvelope: Decodable {
            let code: Int?
            let status: Int?
            let data: JinaReaderDirect?
        }
    
    private struct RAGConfig {
        var tokenToChar: Int = 4          // 1 token ≈ 4 chars
        var triggerTokens: Int = 1000     // run RAG when doc ≥ this many tokens
        var chunkTokens: Int = 1000       // target chunk size in tokens
        var overlapRatio: Double = 0.15   // 15% overlap between chunks
        var topK: Int = 3                 // return this many chunks per large doc
        
        var translateFocusOnMismatch: Bool = true
        var langConfidenceFloor: Double = 0.60
    }
    private var ragConfig = RAGConfig()
    private var currentTask: Task<Void, Never>? = nil
    
    private lazy var httpSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // no ()
        c.timeoutIntervalForRequest = llmRequestTimeout
        c.timeoutIntervalForResource = llmRequestTimeout
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    private lazy var rag: WebRAG = .init(
        chunkSizeChars: ragConfig.chunkTokens * ragConfig.tokenToChar,
        overlapChars: Int(round(Double(ragConfig.chunkTokens * ragConfig.tokenToChar) * ragConfig.overlapRatio))
    )

    private var ragCharThreshold: Int { ragConfig.triggerTokens * ragConfig.tokenToChar }
    
    private func chatURL() throws -> URL {
        if let u = settings.chatCompletionsURL { return u }
        throw NSError(domain: "WebSearchPipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid apiBase in settings"])
    }

    // ====== API ======
    /// Orchestrates the whole flow:
    /// 1) Ask LLM to generate up to 4 search queries
    /// 2) Hit Serper for each query, aggregate/dedupe
    /// 3) Call LLM again (streaming) with web context + user question
    ///
    /// It reuses your existing streaming service for step #3.
    func runSearchAndStream(
        question: String,
        history: [Message],
        service: LMStudioService,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void,
        onStatus: ((WebStatus) -> Void)? = nil
    ) -> Task<Void, Never> {
        let t = Task {
            // Clear any previous cache at the start
            await scrapeCache.clear()
            
            defer {
                // Clear cache when done (success or failure)
                Task {
                    await scrapeCache.clear()
                    await DebugLog.shared.line("CACHE", "Cleared scrape cache")
                }
            }
            
            do {
                onStatus?(.init(stage: .generatingQueries))
                let gen = try await generateQueries(for: question, fullHistory: history)
                let standalone = gen.standalone
                let queries = gen.queries
                if queries.isEmpty {
                    let msgs = self.defaultMessagesFrom(history: history, question: question)
                    service.streamChat(messages: msgs, onChunk: onChunk, onComplete: onComplete, onError: onError)
                    return
                }

                let initialContext = try await fetchWebContext(for: queries)

                var refinedContext = try await refineContextIfNeeded(
                    standaloneQuestion: standalone,
                    initial: initialContext,
                    maxRounds: 3,
                    onStatus: onStatus
                )

                let sz = jsonSizeBytes(refinedContext)
                if sz > 250_000 {
                    print("[web] Final context is \(sz) bytes; clamping aggressively.")
                    refinedContext = refinedContext.aggressivelyClamp(to: 250_000)
                }

                let finalMessages = self.messagesForSecondStage(
                    history: history,
                    question: question,
                    webContext: refinedContext
                )
                service.streamChat(messages: finalMessages, onChunk: onChunk, onComplete: onComplete, onError: onError)
            } catch is CancellationError {
                // Silently end
            } catch {
                onError(error)
            }
        }
        // cancel any previous run
        self.currentTask?.cancel()
        self.currentTask = t
        return t
    }
    
    
    func cancelRunning() {
        currentTask?.cancel()
        currentTask = nil
        Task {
            await localScraper.cancelAllTasks()
            await scrapeCache.clear()
            await DebugLog.shared.line("CACHE", "Cleared scrape cache on cancel")
        }
    }
    

    // Public method to change scraping mode
    func setScrapingMode(_ mode: ScrapingMode) {
        self.scrapingMode = mode
        print("[WebSearchPipeline] Scraping mode set to: \(mode)")
    }

    // MARK: - Stage 1: Query generation (non-streaming)
    private func generateQueries(for question: String, fullHistory: [Message]) async throws -> (standalone: String, queries: [String]) {
        // Build a full transcript (oldest → newest)
        let transcript = fullTranscript(from: fullHistory)

        let sys = """
        You are a query generator. **Today is: \(nowStamp())**
        Your job has TWO parts in one JSON:
          1) Write a single STAND-ALONE question that fully captures the user's true intent, including any constraints, entities, dates, counts, languages, preferences, or follow-ups implied by the full conversation.
          2) Produce up to 4 web search queries to retrieve the most critical information to answer that stand-alone question. If there is multiple stuff you don't know or don't understand, use the queries to search those different things (you will later be allowed follow up queries to respond properly).

        OUTPUT STRICT JSON ONLY (no backticks, no prose) with this exact schema:
        {
          "standalone": "<one sentence, ≤ 100 words>",
          "queries": ["...", "..."]
        }

        RULES FOR QUERIES:
        - ≤ 20 words each, no trailing punctuation.
        - Prefer authoritative sources (e.g., site:developer.apple.com, site:who.int, site:wikipedia.org) when relevant.
        - Add recency hints (years/months) when useful.
        - Avoid vague terms like "best", "top", "ultimate".
        - Quote exact entities if needed.
        """

        let user = """
        FULL_CONVERSATION (oldest→newest):
        \(transcript)

        LATEST_USER_MESSAGE:
        \(question)
        """

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ["role": "system", "content": sys],
                ["role": "user", "content": user]
            ],
            max_tokens: 8000,
            stream: false
        )

        let data = try await httpJSONPost(
            url: try chatURL(),
            body: body,
            extraHeaders: [:],
            timeout: llmRequestTimeout
        )
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)

        guard let content = response.choices.first?.message?.content else {
            // Fallback: use the raw question + naive queries
            return (standalone: question, queries: naiveQueries(from: question))
        }

        if let d = extractFirstJSONObjectData(from: content) {
            // Try v2 first
            if let v2 = try? JSONDecoder().decode(GeneratedQueriesV2.self, from: d) {
                let standalone = v2.standalone.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = v2.queries
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(4)
                if !standalone.isEmpty && !cleaned.isEmpty {
                    return (standalone: standalone, queries: Array(cleaned))
                }
            }
            // Fallback to old shape if model returned only "queries"
            if let v1 = try? JSONDecoder().decode(GeneratedQueries.self, from: d) {
                let cleaned = v1.queries
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(4)
                if !cleaned.isEmpty {
                    return (standalone: question, queries: Array(cleaned))
                }
            }
        }

        // Last resort
        return (standalone: question, queries: naiveQueries(from: question))
    }
    
    private func extractFirstJSONObjectData(from text: String) -> Data? {
        // 1) Strip markdown fences if present
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("") {
            if let start = s.range(of: "")?.upperBound,
               let end = s[start...].range(of: "`")?.lowerBound {
                s = String(s[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Quick path: try as-is
        if let d = s.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: d)) != nil {
            return d
        }
        // 2) Extract the first balanced {...} block, respecting strings/escapes
        let chars = Array(s)
        var depth = 0
        var inString = false
        var escape = false
        var start: Int? = nil

        for i in chars.indices {
            let c = chars[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; continue }
            if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}" {
                if depth > 0 { depth -= 1 }
                if depth == 0, let s0 = start {
                    let slice = String(chars[s0...i])
                    if let d = slice.data(using: .utf8),
                       (try? JSONSerialization.jsonObject(with: d)) != nil {
                        return d
                    }
                    // Keep scanning—there might be another valid object later
                    start = nil
                }
            }
        }
        return nil
    }

    private func naiveQueries(from question: String) -> [String] {
        let q = question
            .lowercased()
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: "", options: .regularExpression)

        let tokens = q.split(separator: " ").map(String.init)
        let core = tokens.filter { $0.count > 2 }.prefix(6).joined(separator: " ")
        if core.isEmpty { return [] }
        return [core, "site:wikipedia.org \(core)"]
    }

    // MARK: - Stage 2: Serper aggregation
    private func fetchWebContext(for queries: [String]) async throws -> WebContext {
        try Task.checkCancellation()
        // Parallel fetch
        var perQueryResults = [(String, SerperResponse)]()
        perQueryResults.reserveCapacity(queries.count)

        try await withThrowingTaskGroup(of: (String, SerperResponse).self) { group in
            for q in queries {
                group.addTask {
                    let r = try await self.serperSearch(q)
                    return (q, r)
                }
            }
            for try await pair in group {
                perQueryResults.append(pair)
            }
        }

        // Flatten, dedupe by link, clamp to max counts
        var seen = Set<String>()
        var allOrganic: [WebResult] = []

        var collectedAnswerBox: AnswerBox?
        var collectedKG: KnowledgeGraph?
        var collectedPAA: [PeopleAlsoAskItem] = []
        var collectedTop: [TopStory] = []

        for (q, resp) in perQueryResults {
            // organic
            if let org = resp.organic {
                for item in org.prefix(maxOrganicPerQuery) {
                    guard let link = item.link, let title = item.title else { continue }
                    let norm = self.normalize(link: link)
                    guard !seen.contains(norm) else { continue }
                    seen.insert(norm)

                    let result = WebResult(
                        title: title,
                        snippet: (item.snippet ?? "").truncated(to: maxSnippetChars),
                        link: link,
                        source: URL(string: link)?.host?.lowercased() ?? "",
                        date: item.date
                    )
                    allOrganic.append(result)
                    if allOrganic.count >= maxTotalResults { break }
                }
            }
            // other rich objects (keep the first we find; concatenate PAAs & TopStories)
            if collectedAnswerBox == nil, let ab = resp.answerBox { collectedAnswerBox = ab }
            if collectedKG == nil, let kg = resp.knowledgeGraph { collectedKG = kg }
            if let paa = resp.peopleAlsoAsk { collectedPAA.append(contentsOf: paa.prefix(6)) }
            if let top = resp.topStories { collectedTop.append(contentsOf: top.prefix(6)) }

            if allOrganic.count >= maxTotalResults { break }
        }

        let ctx = WebContext(
            queries_used: queries,
            results: allOrganic,
            answerBox: collectedAnswerBox,
            knowledgeGraph: collectedKG,
            peopleAlsoAsk: Array(collectedPAA.prefix(8)),
            topStories: Array(collectedTop.prefix(8))
        )

        return ctx.clampedJSONSize(maxBytes: maxContextBytes)
    }
    
    // Current date/time stamp for prompts (local + UTC)
    private func nowStamp() -> String {
        let now = Date()
        let tz = TimeZone.current
        
        // 1. Local, Human-Readable (Kept in English for System Prompt consistency)
        let localFmt = DateFormatter()
        localFmt.timeZone = tz
        localFmt.locale = Locale(identifier: "en_US_POSIX")
        localFmt.dateStyle = .full
        localFmt.timeStyle = .medium
        let localStr = localFmt.string(from: now)
        
        // 2. Technical Context (Cleaner implementation)
        // We replace the manual math loop with the standard formatter "ZZZZZ"
        let offsetFmt = DateFormatter()
        offsetFmt.timeZone = tz
        offsetFmt.dateFormat = "ZZZZZ" // Automatically produces "+01:00" or "-05:00"
        let offsetStr = offsetFmt.string(from: now)
        let tzid = tz.identifier
        
        // 3. UTC ISO (Ground Truth)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone]
        let utcStr = iso.string(from: now)
        
        // Result: "Thursday, December... (Europe/Rome, UTC+01:00) | 2025-12-..."
        return "\(localStr) (\(tzid), UTC\(offsetStr)) | \(utcStr)"
    }
    
    private func jsonSizeBytes<T: Encodable>(_ value: T) -> Int {
        (try? JSONEncoder().encode(value).count) ?? 0
    }

    private func serperSearch(_ query: String) async throws -> SerperResponse {
        let key = settings.serperApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "WebSearchPipeline", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Serper API key is missing. Add it in Settings → Web Search."])
        }

        struct Req: Encodable { let q: String; let num: Int; let autocorrect: Bool }
        let body = Req(q: query, num: maxOrganicPerQuery, autocorrect: true)

        let data = try await httpJSONPost(
            url: serperSearchURL,
            body: body,
            extraHeaders: ["X-API-KEY": key],
            timeout: serperRequestTimeout
        )
        return try JSONDecoder().decode(SerperResponse.self, from: data)
    }
    
    // Decide if the current web context is enough or suggest up to 2 more queries.
    private func assessCoverage(standaloneQuestion: String, context: WebContext) async throws -> RefinementDecision {
        let system = """
        **Today is: \(nowStamp())**
        You are a *content evaluator*.
        Decide whether the WEB_CONTEXT_JSON.results and the scraped content (if present) contain all the information needed to answer fully the stand-alone question.

        You have THREE options:
        1) If it contains the information, go straight to the final answer by setting "enough": true.
        2) If it doesn't, scrape up to 3 most promising URLs from WEB_CONTEXT_JSON.results to extract full page text.
        3) If it doesn't and you think the queries weren't ideal to reach the correct answer, generate 2 additional queries that might get the right results.

        Return STRICT JSON ONLY (no backticks, no prose), matching this schema:
        {
          "enough": true|false,
          "scrape": [
            {
              "url": "<one of results[*].link>",
              "focus": "<a query to locate with sentence embedding the pertinent content on this page.>"
            }
          ],
          "additional_queries": ["<query1>", "<query2>"]
        }

        RULES:
        - Every object in "scrape" must have a "url" that exists in WEB_CONTEXT_JSON.
        - Keep "scrape" ≤ 3, unique. Prefer authoritative, primary, and recent sources.
        - "focus" must be a *standalone* retrieval query for this exact URL.
        - If the current context already covers the answer, set "enough": true and leave arrays empty.
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ctxJSON = (try? String(data: encoder.encode(context), encoding: .utf8)) ?? "{}"

        let user = """
        STANDALONE_QUESTION:
        \(standaloneQuestion)

        WEB_CONTEXT_JSON:
        \(ctxJSON)
        """

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            max_tokens: 8000,
            stream: false
        )

        let data = try await httpJSONPost(
            url: try chatURL(),
            body: body,
            extraHeaders: [:],
            timeout: llmRequestTimeout
        )
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = response.choices.first?.message?.content else {
            return .init(enough: true, additional_queries: [], scrape: [], scrape_links: [])
        }

        if let d = extractFirstJSONObjectData(from: content),
           var dec = try? JSONDecoder().decode(RefinementDecision.self, from: d) {

            // sanitize
            let cleanedQueries = (dec.additional_queries ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let cleanedScrapeLinks = (dec.scrape_links ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var cleanedPlans: [ScrapePlan]? = nil
            if let plans = dec.scrape, !plans.isEmpty {
                var seen = Set<String>()
                cleanedPlans = Array(
                    plans.compactMap { p in
                        let url = p.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !url.isEmpty else { return nil }
                        let key = url.lowercased()
                        guard !seen.contains(key) else { return nil }
                        let focus = p.focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !focus.isEmpty else { return nil }
                        seen.insert(key)
                        return ScrapePlan(url: url, focus: focus)
                    }
                    .prefix(3)
                )
            }

            let out = RefinementDecision(
                enough: dec.enough,
                additional_queries: Array(cleanedQueries.prefix(2)),
                scrape: cleanedPlans,
                scrape_links: Array(cleanedScrapeLinks.prefix(3))
            )
            return out
        }

        // If we can't parse, proceed as "enough"
        return .init(enough: true, additional_queries: [], scrape: [], scrape_links: [])
    }
    
    private func fullTranscript(from history: [Message]) -> String {
        let ordered = history.sorted { $0.timestamp < $1.timestamp }
        return ordered.map { m in
            let who = m.isUser ? "User" : "Assistant"
            // Use plain text; the model doesn't need Markdown here
            return "\(who): \(m.content)"
        }.joined(separator: "\n---\n")
    }
    
    private actor ScrapeCache {
        private var cache: [String: ScrapedDoc] = [:]
        
        func get(_ url: String) -> ScrapedDoc? {
            cache[url.lowercased()]
        }
        
        func set(_ url: String, doc: ScrapedDoc) {
            cache[url.lowercased()] = doc
        }
        
        func clear() {
            cache.removeAll()
        }
        
        func getCacheSize() -> Int {
            cache.count
        }
    }
    
    // MARK: - Unified scraping method that routes to either Serper API or local WebKit
    private func scrapeURL(_ urlStr: String) async throws -> ScrapedDoc {
        if let cached = await scrapeCache.get(urlStr) {
            await DebugLog.shared.line("CACHE", "Hit for \(urlStr)")
            return cached
        }

        let doc: ScrapedDoc
        switch settings.scrapingMode {
        case .serperAPI:
            // CHANGED: use Jina Reader for remote scraping
            doc = try await jinaScrape(urlStr)                // ← NEW
        case .localWebKit:
            doc = try await localScraper.scrapeURL(urlStr)    // existing
        }

        await scrapeCache.set(urlStr, doc: doc)
        await DebugLog.shared.line("CACHE", "Stored \(urlStr) (cache size: \(await scrapeCache.getCacheSize()))")
        return doc
    }
    
    func httpJSONPostBare<T: Encodable>(
            url: URL,
            body: T,
            headers: [String: String],
            timeout: TimeInterval
        ) async throws -> Data {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = try JSONEncoder().encode(body)
            req.timeoutInterval = timeout

            try Task.checkCancellation()
            let (data, resp) = try await httpSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NSError(domain: "WebSearchPipeline.HTTP", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response calling \(url.absoluteString)"])
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "WebSearchPipeline.HTTP", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) calling \(url.absoluteString)\n\(body.prefix(500))"])
            }
            return data
        }
    
    func jinaScrape(_ urlStr: String) async throws -> ScrapedDoc {
            // Build headers: JSON response + optional Authorization
            var headers: [String: String] = [
                "Accept": "application/json",
                // The following is optional; defaults favor quality. Tweak to taste:
                "X-Engine": "browser",               // high quality render for JS-y sites
                "X-Retain-Images": "none"
                // "X-Return-Format": "markdown",   // default is Markdown in 'content'
                // "X-Token-Budget": "80000"        // optional token safety rail
            ]
            let key = settings.jinaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                headers["Authorization"] = "Bearer \(key)"
            }
            // If you ever want EU-only processing:
            // let endpoint = URL(string: "https://eu.r.jina.ai/")!

            // POST JSON { "url": "<target>" } to Reader
            let data = try await httpJSONPostBare(
                url: jinaReaderURL,
                body: JinaReaderReq(url: urlStr),
                headers: headers,
                timeout: 90
            )

            // Try direct JSON first
            let decoder = JSONDecoder()
            if let direct = try? decoder.decode(JinaReaderDirect.self, from: data),
               (direct.content?.isEmpty == false || direct.title?.isEmpty == false) {
                let host = URL(string: urlStr)?.host?.lowercased() ?? ""
                return ScrapedDoc(
                    url: direct.url ?? urlStr,
                    source: host,
                    title: direct.title,
                    markdown: direct.content,  // markdown payload
                    text: nil,
                    ragChunks: nil,
                    ragQuery: nil,
                    ragQueryOriginal: nil,
                    ragDocLang: nil,
                    ragQueryLang: nil
                )
            }

            // Try envelope JSON
            if let env = try? decoder.decode(JinaReaderEnvelope.self, from: data),
               let d = env.data,
               (d.content?.isEmpty == false || d.title?.isEmpty == false) {
                let host = URL(string: urlStr)?.host?.lowercased() ?? ""
                return ScrapedDoc(
                    url: d.url ?? urlStr,
                    source: host,
                    title: d.title,
                    markdown: d.content,
                    text: nil,
                    ragChunks: nil,
                    ragQuery: nil,
                    ragQueryOriginal: nil,
                    ragDocLang: nil,
                    ragQueryLang: nil
                )
            }

            // Fallback: some deployments return plain text/markdown even with Accept header.
            if let md = String(data: data, encoding: .utf8), !md.isEmpty {
                let host = URL(string: urlStr)?.host?.lowercased() ?? ""
                return ScrapedDoc(
                    url: urlStr,
                    source: host,
                    title: nil,
                    markdown: md,
                    text: nil,
                    ragChunks: nil,
                    ragQuery: nil,
                    ragQueryOriginal: nil,
                    ragDocLang: nil,
                    ragQueryLang: nil
                )
            }

            throw NSError(domain: "WebSearchPipeline.Jina", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Reader returned empty body for \(urlStr)"])
        }
    
    private struct SerperScrapeReq: Encodable {
        let url: String
        let includeMarkdown: Bool = true
    }

    private struct SerperScrapeResp: Decodable {
        let url: String?
        let title: String?
        let markdown: String?
        let text: String?
        // unknown fields are ignored automatically
    }

    private func serperScrape(_ urlStr: String) async throws -> ScrapedDoc {
        let key = settings.serperApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "WebSearchPipeline", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Serper API key is missing. Add it in Settings → Web Search."])
        }

        let data = try await httpJSONPost(
            url: serperScrapeURL,
            body: SerperScrapeReq(url: urlStr),
            extraHeaders: ["X-API-KEY": key],
            timeout: serperRequestTimeout
        )
        let resp = try JSONDecoder().decode(SerperScrapeResp.self, from: data)
        let host = URL(string: urlStr)?.host?.lowercased() ?? ""
        return ScrapedDoc(
            url: urlStr,
            source: host,
            title: resp.title,
            markdown: resp.markdown,
            text: resp.text
        )
    }

    // Loop up to maxRounds. If LLM asks for more, query Serper again and merge.
    private func refineContextIfNeeded(
        standaloneQuestion: String,
        initial: WebContext,
        maxRounds: Int,
        onStatus: ((WebStatus) -> Void)? = nil
    ) async throws -> WebContext {
        var context = initial
        var rounds = 0

        await DebugLog.shared.line(
            "REFINE",
            "Begin refine (maxRounds=\(maxRounds)); queries=\(context.queries_used.count), results=\(context.results.count), scraped=\(context.scraped?.count ?? 0), size=\(jsonSizeBytes(context))B"
        )

        while rounds < maxRounds {
            try Task.checkCancellation()
            rounds += 1

            // 🔹 Let UI know we're analyzing what we have
            onStatus?(.init(stage: .analyzingResults))

            let decision = try await assessCoverage(standaloneQuestion: standaloneQuestion, context: context)
            await DebugLog.shared.line(
                "REFINE",
                "Round \(rounds): decision enough=\(decision.enough) " +
                "scrapes=\(decision.scrape?.count ?? decision.scrape_links?.count ?? 0) " +
                "addQ=\(decision.additional_queries?.count ?? 0) "
            )

            if decision.enough {
                await DebugLog.shared.line("REFINE", "Round \(rounds): enough=true → stopping refinement")
                break
            }

            // Build scrape plan (existing code) ...
            var plan: [(url: String, focus: String?)] = []

            if let scrapeObjs = decision.scrape, !scrapeObjs.isEmpty {
                for item in scrapeObjs.prefix(3) {
                    let raw = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { continue }
                    let key = self.normalize(link: raw).lowercased()

                    // Map to canonical link in current results
                    let linkMap: [String: String] = Dictionary(
                        uniqueKeysWithValues: context.results.map { (self.normalize(link: $0.link).lowercased(), $0.link) }
                    )
                    guard let canonical = linkMap[key] else { continue }

                    let f = item.focus.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !f.isEmpty else { continue }

                    plan.append((url: canonical, focus: f))
                }
            } else if let wantScrapes = decision.scrape_links, !wantScrapes.isEmpty {
                let linkMap: [String: String] = Dictionary(
                    uniqueKeysWithValues: context.results.map { (self.normalize(link: $0.link).lowercased(), $0.link) }
                )
                for raw in wantScrapes.prefix(3) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let key = self.normalize(link: trimmed).lowercased()
                    guard let canonical = linkMap[key] else { continue }
                    plan.append((url: canonical, focus: nil)) // legacy, no focus provided
                }
            }

                    // 🔹 If we're about to scrape, emit the URLs
                    if !plan.isEmpty {
                        onStatus?(.init(scraping: plan.map { $0.url }))
                    }

            // Prepare additional queries (dedup against those already used)
            let usedQueries = Set(context.queries_used.map { $0.lowercased() })
            let newQueries = (decision.additional_queries ?? []).filter { !usedQueries.contains($0.lowercased()) }

            // If the model asked for more but gave us no actionable items, bail out to avoid infinite loops
            if plan.isEmpty && newQueries.isEmpty {
                await DebugLog.shared.line("REFINE", "Round \(rounds): no actionable scrapes or queries; stopping.")
                break
            }

            // === 1) Run scrapes (if any) ===
            if !plan.isEmpty {
                await DebugLog.shared.line("REFINE", "Round \(rounds): scraping \(plan.count) URL(s)")

                // Build per-URL focus map (keyed by lowercased URL)
                var focusMap: [String: String] = [:]
                for p in plan {
                    if let f = p.focus {
                        focusMap[p.url.lowercased()] = f
                    }
                }

                var scrapedDocs: [ScrapedDoc] = []
                await withTaskGroup(of: (String, Result<ScrapedDoc, Error>).self) { group in
                    for (link, _) in plan {
                        group.addTask {
                            do { return (link, .success(try await self.scrapeURL(link))) }
                            catch { return (link, .failure(error)) }
                        }
                    }
                    for await (link, result) in group {
                        switch result {
                        case .success(let doc):
                            scrapedDocs.append(doc)
                            if debug.logScrapeSummaries {
                                let tLen = doc.text?.count ?? 0
                                let mLen = doc.markdown?.count ?? 0
                                await DebugLog.shared.line("SCRAPE", "OK \(link) text=\(tLen) markdown=\(mLen)")
                            }
                        case .failure(let err):
                            if debug.logScrapeFailures {
                                await DebugLog.shared.error("SCRAPE", "FAILED \(link)", err: err)
                            }
                        }
                    }
                }

                // Dump full bodies BEFORE any RAG trimming (very verbose)
                if debug.dumpFullScrapes {
                    for d in scrapedDocs {
                        await DebugLog.shared.scrapeDump(url: d.url, content: d.markdown ?? d.text)
                    }
                }

                // Attach per-URL focus to docs and apply RAG if needed
                if !scrapedDocs.isEmpty {
                    for i in scrapedDocs.indices {
                        let key = scrapedDocs[i].url.lowercased()
                        if let focus = focusMap[key] {
                            scrapedDocs[i].ragQuery = focus
                        }
                    }
                    scrapedDocs = await self.applyRAGIfNeeded(
                        to: scrapedDocs,
                        globalQuery: standaloneQuestion,
                        perDocFocus: focusMap
                    )
                    
                    if debug.dumpRAGChunksOnly {
                        for d in scrapedDocs {
                            await DebugLog.shared.ragChunksDump(
                                url: d.url,
                                title: d.title,
                                ragQuery: d.ragQuery,
                                chunks: d.ragChunks
                            )
                        }
                    }

                    if debug.dumpAfterRAG {
                        await DebugLog.shared.line("RAG", "Round \(rounds): dumping post-RAG excerpts…")
                        for d in scrapedDocs {
                            await DebugLog.shared.scrapeDump(url: d.url + " [POST-RAG]", content: d.markdown ?? d.text)
                        }
                    }
                }

                // Merge new scrapes into the context (dedupe by URL)
                let before = context.scraped?.count ?? 0
                var seen = Set((context.scraped ?? []).map { $0.url.lowercased() })
                var merged = context.scraped ?? []
                for d in scrapedDocs {
                    let u = d.url.lowercased()
                    if !seen.contains(u) {
                        merged.append(d)
                        seen.insert(u)
                    }
                }
                context.scraped = merged
                let after = merged.count
                await DebugLog.shared.line("REFINE", "Round \(rounds): merged scrapes \(after - before >= 0 ? "+" : "")\(after - before); total scraped=\(after)")
            }

            // === 2) Run additional searches (if any) ===
            if !newQueries.isEmpty {
                await DebugLog.shared.line("REFINE", "Round \(rounds): running extra searches (\(newQueries.count))")
                let beforeResults = context.results.count
                let added = try await fetchWebContext(for: newQueries)
                context = mergeWebContexts(base: context, added: added)
                let afterResults = context.results.count
                await DebugLog.shared.line(
                    "REFINE",
                    "Round \(rounds): merged web results; results=\(afterResults) (\(afterResults - beforeResults >= 0 ? "+" : "")\(afterResults - beforeResults)), queries_used=\(context.queries_used.count)"
                )
            }

            await DebugLog.shared.line(
                "REFINE",
                "Round \(rounds): size=\(jsonSizeBytes(context))B, results=\(context.results.count), scraped=\(context.scraped?.count ?? 0)"
            )
        }

        await DebugLog.shared.line(
            "REFINE",
            "End refine: rounds=\(rounds), final size(before clamp)=\(jsonSizeBytes(context))B"
        )

        // Final clamp to keep the payload bounded
        let clamped = context.clampedJSONSize(maxBytes: maxContextBytes)
        await DebugLog.shared.line("REFINE", "Final size(after clamp)=\(jsonSizeBytes(clamped))B")
        return clamped
    }
    
    private func applyRAGIfNeeded(
        to docs: [ScrapedDoc],
        globalQuery: String,
        perDocFocus: [String: String]? = nil
    ) async -> [ScrapedDoc] {
        var processed = docs

        for i in processed.indices {
            let content = processed[i].markdown ?? processed[i].text ?? ""
            guard !content.isEmpty else { continue }

            if shouldRAG(content: content) {
                // Choose focus: per-URL focus, then any attached ragQuery, then global question
                let key = processed[i].url.lowercased()
                var q = perDocFocus?[key] ?? processed[i].ragQuery ?? globalQuery

                // Detect languages
                let (docLangOpt, docConf) = detectLanguage(content)
                let (qLangOpt,   qConf)   = detectLanguage(q)

                if let docLang = docLangOpt {
                    processed[i].ragDocLang = docLang.rawValue
                }
                if let qLang = qLangOpt {
                    processed[i].ragQueryLang = qLang.rawValue
                }

                // Translate focus if doc/query mismatch and confidence is decent
                if ragConfig.translateFocusOnMismatch,
                   let docLang = docLangOpt, let qLang = qLangOpt,
                   docLang != qLang,
                   docConf >= ragConfig.langConfidenceFloor,
                   qConf   >= ragConfig.langConfidenceFloor
                {
                    if let translated = await translateFocusForRAG(q, into: docLang), !translated.isEmpty {
                        await DebugLog.shared.line(
                            "RAG_LANG",
                            "Translated focus \(qLang.rawValue)→\(docLang.rawValue) for \(processed[i].url)"
                        )
                        processed[i].ragQueryOriginal = q
                        q = translated
                    } else {
                        await DebugLog.shared.line(
                            "RAG_LANG",
                            "Wanted to translate \(qLangOpt?.rawValue ?? "-")→\(docLangOpt?.rawValue ?? "-") but fell back to original focus"
                        )
                    }
                }

                // Now rank with the (possibly translated) focus
                let isMarkdown = (processed[i].markdown != nil)
                let chunks = rag.topChunks(
                    for: content,
                    query: q,
                    url: processed[i].url,
                    topK: ragConfig.topK,
                    payloadIsMarkdown: isMarkdown    // ⬅️ NEW
                )
                processed[i].ragChunks = chunks
                processed[i].ragQuery  = q

                // Keep a small excerpt; rest is trimmed later if needed
                let full = processed[i].markdown ?? processed[i].text ?? ""
                let excerptLimit = min(ragConfig.chunkTokens * ragConfig.tokenToChar, max(1000, full.count / 8))
                let excerpt = String(full.prefix(excerptLimit))
                if processed[i].markdown != nil {
                    processed[i].markdown = excerpt
                    processed[i].text = nil
                } else {
                    processed[i].text = excerpt
                }
            }
        }

        return processed
    }

    private func shouldRAG(content: String) -> Bool {
        return content.count >= ragCharThreshold
    }

    // Merge two WebContext objects (dedupe by normalized link, clamp size)
    private func mergeWebContexts(base: WebContext, added: WebContext) -> WebContext {
        var merged = base

        // Merge queries (keep order, de-dupe)
        var seenQ = Set(merged.queries_used.map { $0.lowercased() })
        for q in added.queries_used where !seenQ.contains(q.lowercased()) {
            merged.queries_used.append(q)
            seenQ.insert(q.lowercased())
        }

        // Dedupe results by normalized link
        var seenLinks = Set(merged.results.map { normalize(link: $0.link) })
        for r in added.results {
            let norm = normalize(link: r.link)
            if !seenLinks.contains(norm) {
                merged.results.append(r)
                seenLinks.insert(norm)
            }
            if merged.results.count >= maxTotalResults { break }
        }

        // Prefer first non-nil rich objects
        if merged.answerBox == nil { merged.answerBox = added.answerBox }
        if merged.knowledgeGraph == nil { merged.knowledgeGraph = added.knowledgeGraph }

        // Append PAA and TopStories, clamp
        var paa = (merged.peopleAlsoAsk ?? []) + (added.peopleAlsoAsk ?? [])
        if paa.count > 8 { paa = Array(paa.prefix(8)) }
        merged.peopleAlsoAsk = paa.isEmpty ? nil : paa

        var ts = (merged.topStories ?? []) + (added.topStories ?? [])
        if ts.count > 8 { ts = Array(ts.prefix(8)) }
        merged.topStories = ts.isEmpty ? nil : ts

        // Keep any existing scraped docs (added never has them)
        return merged.clampedJSONSize(maxBytes: maxContextBytes)
    }

    // JSON shape for the coverage decision
    private struct RefinementDecision: Decodable {
        let enough: Bool
        let additional_queries: [String]?
        let scrape: [ScrapePlan]?     // NEW preferred shape
        let scrape_links: [String]?   // Legacy fallback (no focus text)
    }
    
    private struct ScrapePlan: Codable {
        let url: String
        let focus: String   // standalone "what to extract / confirm" text for this URL
    }

    // MARK: - Stage 3: Build final messages for streaming
    private func messagesForSecondStage(
        history: [Message],
        question: String,
        webContext: WebContext
    ) -> [[String: String]] {

        let system = """
        **Today is: \(nowStamp())**
        You are a meticulous assistant.
        Use the the provided web context and the conversation history below to answer accurately the user's last question.

        REQUIREMENTS:
        - scraped documents are present in WEB_CONTEXT_JSON; they are the fetched page contents.
        - If a scraped doc includes ragChunks, the page was large; those are the most relevant excerpts of those urls.
        - Prefer authoritative, recent sources. If dates exist, state them explicitly (e.g., "Updated March 2025").
        - If sources conflict, note the disagreement briefly and choose the most credible.
        - If evidence is weak or missing, say what's unknown.
        - Keep the main answer concise, then include a short "Sources" section listing the urls you actually used.
        - DO NOT fabricate citations. Only cite items present in WEB_CONTEXT_JSON.
        """

        var msgs: [[String: String]] = [
            ["role": "system", "content": system]
        ]

        // Use FULL history (oldest → newest)
        let ordered = history.sorted { $0.timestamp < $1.timestamp }
        for m in ordered {
            msgs.append([
                "role": m.isUser ? "user" : "assistant",
                "content": m.content
            ])
        }

        // Add a fresh user turn that injects the web context
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ctxJSON = (try? String(data: encoder.encode(webContext), encoding: .utf8)) ?? "{}"
        
        if debug.dumpRAGChunksOnly {
            Task {
                await DebugLog.shared.line("CTX", "WEB_CONTEXT_JSON -> LLM (bytes=\(ctxJSON.utf8.count))")
                await DebugLog.shared.scrapeDump(url: "[WEB_CONTEXT_JSON → LLM]", content: ctxJSON)
            }
        }

        let user = """
        USER_QUESTION:
        \(question)

        WEB_CONTEXT_JSON:
        \(ctxJSON)
        """

        msgs.append(["role": "user", "content": user])
        return msgs
    }

    // Used if web search is disabled or fails
    private func defaultMessagesFrom(history: [Message], question: String) -> [[String: String]] {
        var msgs: [[String: String]] = []
        for m in history {
            msgs.append(["role": m.isUser ? "user" : "assistant", "content": m.content])
        }
        msgs.append(["role": "user", "content": question])
        return msgs
    }

    // MARK: - HTTP helper
    private func httpJSONPost<T: Encodable>(
        url: URL,
        body: T,
        extraHeaders: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var merged = settings.authHeaders
        for (k, v) in extraHeaders { merged[k] = v }
        for (k, v) in merged { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONEncoder().encode(body)

        // Make sure this request can sit for a long generation
        req.timeoutInterval = timeout

        try Task.checkCancellation()
        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "WebSearchPipeline.HTTP", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response calling \(url.absoluteString)"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "WebSearchPipeline.HTTP", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) calling \(url.absoluteString)\n\(body.prefix(500))"])
        }
        return data
    }

    // MARK: - Utils
    private func normalize(link: String) -> String {
        guard var comps = URLComponents(string: link) else { return link }
        // Strip trackers
        comps.queryItems = comps.queryItems?.filter {
            guard let name = $0.name.lowercased() as String? else { return true }
            return !(name.hasPrefix("utm_") || name == "gclid" || name == "fbclid" || name == "igshid")
        }
        comps.fragment = nil
        return comps.string ?? link
    }
    
    
    
    private func detectLanguage(_ text: String, sample: Int = 20_000) -> (lang: NLLanguage?, confidence: Double) {
        let snippet = String(text.prefix(sample))
        let r = NLLanguageRecognizer()
        r.processString(snippet)
        let lang = r.dominantLanguage
        let conf = lang.flatMap { r.languageHypotheses(withMaximum: 1)[$0] } ?? 0.0
        return (lang, conf)
    }

    private func languageEnglishName(for lang: NLLanguage) -> String {
        let code = lang.rawValue  // e.g., "en", "it"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private struct TranslateJSON: Decodable { let translation: String }

    /// Translate short focus strings into the document language, using your existing LLM endpoint.
    private func translateFocusForRAG(_ text: String, into target: NLLanguage) async -> String? {
        let targetName = languageEnglishName(for: target)

        let system = """
        You are a precise technical translator.
        - Translate the user's text into TARGET_LANGUAGE.
        - Preserve numbers, codes, units, URLs, product names, and quoted substrings.
        - Keep punctuation and casing; do NOT add explanations.
        - If the text is already in TARGET_LANGUAGE, return it unchanged.
        Output STRICT JSON ONLY:
        { "translation": "<translated text>" }
        """

        let user = """
        TARGET_LANGUAGE: \(targetName)
        TEXT:
        \(text)
        """

        let body = ChatRequest(
            model: settings.model,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            max_tokens: 512,
            stream: false
        )

        do {
            let data = try await httpJSONPost(
                url: try chatURL(),
                body: body,
                extraHeaders: [:],
                timeout: 60
            )
            let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = resp.choices.first?.message?.content else { return nil }

            // Reuse your existing JSON extractor to be robust to fences
            if let d = extractFirstJSONObjectData(from: content),
               let parsed = try? JSONDecoder().decode(TranslateJSON.self, from: d) {
                let out = parsed.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                return out.isEmpty ? nil : out
            }

            // Fallback: raw content
            let fallback = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? nil : fallback
        } catch {
            await DebugLog.shared.error("RAG_XLATE", "Translation failed", err: error)
            return nil
        }
    }
    
}

// MARK: - Stage 1 types (LM Studio non-stream)
private struct ChatRequest: Encodable {
    let model: String
    let messages: [[String: String]]
    let max_tokens: Int
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let index: Int
        let message: Message?
    }
    let choices: [Choice]
}

private struct GeneratedQueries: Decodable {
    let queries: [String]
}

// New v2 that also returns a canonical, stand-alone question
private struct GeneratedQueriesV2: Decodable {
    let standalone: String
    let queries: [String]
}

// MARK: - Stage 2 types (Serper)
private struct SerperResponse: Decodable {
    let answerBox: AnswerBox?
    let knowledgeGraph: KnowledgeGraph?
    let peopleAlsoAsk: [PeopleAlsoAskItem]?
    let topStories: [TopStory]?
    let organic: [Organic]?

    struct Organic: Decodable {
        let title: String?
        let link: String?
        let snippet: String?
        let date: String?
    }
}

private struct AnswerBox: Codable {
    let answer: String?
    let snippet: String?
    let title: String?
    let link: String?
    let type: String?
}

private struct KnowledgeGraph: Codable {
    let title: String?
    let type: String?
    let description: String?
    let source: String?
    let url: String?
}

private struct PeopleAlsoAskItem: Codable {
    let question: String?
    let snippet: String?
    let title: String?
    let link: String?
}

private struct TopStory: Codable {
    let title: String?
    let link: String?
    let source: String?
    let date: String?
}

struct ScrapedDoc: Codable {
    let url: String
    let source: String        // host
    let title: String?
    var markdown: String?     // var so we can trim
    var text: String?         // var so we can trim
    var ragChunks: [RAGChunk]?  // distilled, most relevant chunks
    var ragQuery: String?       // <-- NEW: per-URL focus used for chunking
    
    var ragQueryOriginal: String?
    var ragDocLang: String?
    var ragQueryLang: String?
}

private struct WebContext: Codable {
    var queries_used: [String]
    var results: [WebResult]
    var answerBox: AnswerBox?
    var knowledgeGraph: KnowledgeGraph?
    var peopleAlsoAsk: [PeopleAlsoAskItem]?
    var topStories: [TopStory]?
    var scraped: [ScrapedDoc]?   // NEW

    /// We intentionally never drop scraped here (per your request).
    func clampedJSONSize(maxBytes: Int) -> WebContext {
        let enc = JSONEncoder()

        func sized(_ w: WebContext) -> Int {
            (try? enc.encode(w)).map { $0.count } ?? Int.max
        }

        // Start with current
        var trimmed = self
        if sized(trimmed) <= maxBytes { return trimmed }

        // 1) Prefer RAG chunks over long full texts: if a doc has ragChunks, drop its full text/markdown entirely.
        if var scraped = trimmed.scraped {
            var changed = false
            for i in scraped.indices {
                if scraped[i].ragChunks != nil {
                    if scraped[i].markdown != nil || scraped[i].text != nil {
                        scraped[i].markdown = nil
                        scraped[i].text = nil
                        changed = true
                    }
                }
            }
            if changed {
                trimmed.scraped = scraped
                if sized(trimmed) <= maxBytes { return trimmed }
            }
        }

        // 2) Reduce number of results
        trimmed.results = Array(results.prefix(8))
        if sized(trimmed) <= maxBytes { return trimmed }

        // 3) Drop optional rich blocks (keep scraped + ragChunks)
        trimmed.answerBox = nil
        trimmed.peopleAlsoAsk = nil
        trimmed.topStories = nil
        if sized(trimmed) <= maxBytes { return trimmed }

        // 4) Final clamp of results
        trimmed.results = Array(results.prefix(5))
        return trimmed
    }
}

private extension WebContext {
    func aggressivelyClamp(to maxBytes: Int) -> WebContext {
        var t = self

        // Hard limit page bodies to ~2000 chars each
        if var s = t.scraped {
            for i in s.indices {
                if let m = s[i].markdown, m.count > 2000 { s[i].markdown = String(m.prefix(2000)) }
                if let tx = s[i].text, tx.count > 2000 { s[i].text = String(tx.prefix(2000)) }
            }
            t.scraped = s
        }
        return t.clampedJSONSize(maxBytes: maxBytes)
    }
}

private struct WebResult: Codable {
    let title: String
    let snippet: String
    let link: String
    let source: String
    let date: String?
}

private extension String {
    func truncated(to maxChars: Int) -> String {
        guard count > maxChars else { return self }
        return String(prefix(maxChars - 1)) + "…"
    }
}
