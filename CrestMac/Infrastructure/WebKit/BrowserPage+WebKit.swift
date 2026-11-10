import Foundation
import WebKit

/// The page's WebKit-only state, read by its WebKit delegate conformances and
/// bridges. Each is empty when another engine hosts the page.
extension BrowserPage {
    var webKitAdapter: BrowserWebKitPageAdapter? { engineAdapter as? BrowserWebKitPageAdapter }
    /// The page WebKit's binding built for this page, or nil when another
    /// engine hosts it.
    var webKitEnginePage: WebKitEnginePage? { webKitAdapter?.webKitPage }
    var webKitView: WKWebView? { webKitAdapter?.webView }

    var activeNavigation: WKNavigation? {
        get { webKitAdapter?.activeNavigation }
        set { webKitAdapter?.activeNavigation = newValue }
    }

    /// Supplemental history for link entries WebKit leaves out of its lists.
    var navigationHistory: BrowserPageNavigationHistory {
        get { webKitAdapter?.webKit.history ?? BrowserPageNavigationHistory() }
        set { webKitAdapter?.webKit.history = newValue }
    }

    var geolocationCoordinator: BrowserGeolocationCoordinator? { webKitAdapter?.geolocationCoordinator }

    func applyContentBlocking(
        policy: ContentBlockingPolicy,
        balancedRuleLists: [WKContentRuleList],
        activation: BrowserContentRuleListActivation = .onNextNavigation
    ) {
        webKitAdapter?.applyContentBlocking(
            policy: policy,
            balancedRuleLists: balancedRuleLists,
            reloadsImmediately: activation == .immediately && pageEngine.currentURL != nil
        )
    }

    func updateUnderPageBackground() {
        webKitView?.underPageBackgroundColor =
            completedNavigationCount == 0 ? .clear : nil
    }

    /// Tells the core the page's current navigation failed with `error`,
    /// which `replacedDocument` when it came after the new document took the
    /// page's place. A navigation that became a download or was cancelled is
    /// no failure, and only ends.
    func recordNavigationFailure(
        _ error: any Error,
        replacedDocument: Bool,
        navigation: WKNavigation?
    ) {
        guard isCurrentNavigation(navigation), let reporter = webKitAdapter?.reporter else { return }
        activeNavigation = nil
        // A load that ends here commits no entry to take the core's identity.
        navigationHistory.expectEntry(nil)
        if let failure = PageFailure(
            error: error, replacedDocument: replacedDocument, fallbackURL: reporter.pendingURL ?? webKitView?.url)
        {
            reporter.failed(failure)
        } else {
            reporter.interrupted()
        }
    }

    /// Whether this page's own web view sent `scriptMessage`.
    ///
    /// A popup shares its opener's `WKUserContentController`, so the opener's
    /// user scripts run inside the popup's document and post to the opener's
    /// handlers. Without this check a popup's form would be read against the
    /// opener's top-level origin, and an accepted fill would be evaluated in the
    /// opener's web view against a frame belonging to the popup's.
    private func isOwnScriptMessage(_ scriptMessage: WKScriptMessage) -> Bool {
        scriptMessage.webView === webKitView
    }

    /// Reads what the credential bridge posted from this page's web view. A
    /// popup shares this page's controller, so its bridge posts here too: a
    /// message another page's web view sent goes to that page, whose own
    /// credential session reads it and fills its own frames.
    func receiveCredentialMessage(_ scriptMessage: WKScriptMessage) {
        guard let webView = webKitView else { return }
        if let source = scriptMessage.webView, source !== webView {
            webKitEnginePage?.binding?.page(showing: source)?.host?.receiveCredentialMessage(scriptMessage)
            return
        }
        credentialSession.receive(scriptMessage, in: webView)
    }

    /// Answers the cosmetic bridge of this page's web view, or hands a
    /// popup's message, which arrives through its opener's controller, to the
    /// popup's own page.
    func receiveCosmeticFilterMessage(_ scriptMessage: WKScriptMessage) {
        guard let webView = webKitView else { return }
        if let source = scriptMessage.webView, source !== webView {
            webKitEnginePage?.binding?.page(showing: source)?.host?
                .receiveCosmeticFilterMessage(scriptMessage)
            return
        }
        let session =
            cosmeticFilters
            ?? BrowserCosmeticFilterSession(
                webView: webView, core: downloadCenter.core, spaceID: spaceID, picker: elementPicker)
        cosmeticFilters = session
        session.receive(scriptMessage)
    }

    /// Records the link the person just right-clicked, moments before WebKit
    /// hands AppKit the menu that right-click opens.
    func receiveLinkContextMessage(_ scriptMessage: WKScriptMessage) {
        guard isOwnScriptMessage(scriptMessage),
            scriptMessage.name
                == BrowserLinkContextContentBridge.messageHandlerName
        else { return }
        if scriptMessage.frameInfo.isMainFrame,
            let activation = BrowserDownloadSourceCapture(
                messageBody: scriptMessage.body
            )
        {
            downloadSourceStore.record(activation)
            return
        }
        linkContextCapture.record(
            body: scriptMessage.body,
            documentURL: scriptMessage.frameInfo.request.url,
            isMainFrame: scriptMessage.frameInfo.isMainFrame
        )
    }
}

// MARK: - WebKit hosting

extension BrowserPage: WebKitPageHosting {
    /// The page shows itself heading to `url`, which only an app-initiated
    /// load may reach when it is a local file.
    func prepareToLoad(_ url: URL) {
        appInitiatedURL = url
        prepareForNavigation(to: url)
    }

    func mediaActivityMayHaveChanged() {
        refreshMediaActivity()
    }

    func historyMayHaveChanged() {
        navigationReporter?.reportHistoryAgain()
    }
}

// MARK: - Autofill

private var activeAutofillTargetFrameKey: UInt8 = 0
private var activeAutofillHandleIDKey: UInt8 = 0
private var activeAutofillFrameTokenKey: UInt8 = 0

extension BrowserPage {
    var activeAutofillTargetFrame: WKFrameInfo? {
        get {
            objc_getAssociatedObject(self, &activeAutofillTargetFrameKey) as? WKFrameInfo
        }
        set {
            objc_setAssociatedObject(self, &activeAutofillTargetFrameKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    var activeAutofillHandleID: UUID? {
        get {
            objc_getAssociatedObject(self, &activeAutofillHandleIDKey) as? UUID
        }
        set {
            objc_setAssociatedObject(self, &activeAutofillHandleIDKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    var activeAutofillFrameToken: String? {
        get {
            objc_getAssociatedObject(self, &activeAutofillFrameTokenKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &activeAutofillFrameTokenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func invalidateAutofillFocusTarget() {
        activeAutofillTargetFrame = nil
        activeAutofillHandleID = nil
        activeAutofillFrameToken = nil
        autofillSession?.dismiss()
    }

    /// Normalizes scheme, host, and port into a canonical origin string.
    private static func canonicalOrigin(protocol proto: String, host: String, port: Int) -> String {
        let normalizedPort: Int
        if port == 0 {
            if proto.lowercased() == "https" {
                normalizedPort = 443
            } else if proto.lowercased() == "http" {
                normalizedPort = 80
            } else {
                normalizedPort = 0
            }
        } else {
            normalizedPort = port
        }
        return "\(proto.lowercased())://\(host.lowercased()):\(normalizedPort)"
    }

    func receiveAutofillMessage(_ scriptMessage: WKScriptMessage) {
        guard let webView = webKitView else { return }
        if let source = scriptMessage.webView, source !== webView {
            webKitEnginePage?.binding?.page(showing: source)?.host?.receiveAutofillMessage(scriptMessage)
            return
        }
        // Enforce privacy configuration readiness
        guard let session = ensureAutofillSession() else { return }

        guard let dict = scriptMessage.body as? [String: Any],
            let event = dict["event"] as? String else { return }

        let origin = scriptMessage.frameInfo.securityOrigin
        guard !origin.host.isEmpty else { return }
        let originString = Self.canonicalOrigin(
            protocol: origin.protocol,
            host: origin.host,
            port: origin.port
        )

        let frameToken = dict["frameToken"] as? String

        if event == "blur" {
            // Validate blur against the active focus frame token (stable per document/frame)
            if let activeToken = activeAutofillFrameToken, let frameToken, activeToken == frameToken {
                if let handleID = activeAutofillHandleID {
                    session.receiveMessage(
                        dict,
                        frameSecurityOrigin: originString,
                        isMainFrame: scriptMessage.frameInfo.isMainFrame,
                        navigationGeneration: navigationGeneration,
                        frameHandleID: handleID
                    )
                }
                if session.activeField == nil {
                    activeAutofillTargetFrame = nil
                    activeAutofillHandleID = nil
                    activeAutofillFrameToken = nil
                }
            }
            return
        }

        guard event == "focus" else { return }

        // Reject tokenless or empty frameToken to prevent undismissable focus states
        guard let validFrameToken = frameToken, !validFrameToken.isEmpty else { return }

        let handleID = UUID()
        activeAutofillTargetFrame = scriptMessage.frameInfo
        activeAutofillHandleID = handleID
        activeAutofillFrameToken = validFrameToken

        session.receiveMessage(
            dict,
            frameSecurityOrigin: originString,
            isMainFrame: scriptMessage.frameInfo.isMainFrame,
            navigationGeneration: navigationGeneration,
            frameHandleID: handleID
        )
    }

    func fillAutofillIdentity(_ identity: AutofillIdentity, targetFrame: WKFrameInfo? = nil) async throws {
        guard let session = autofillSession, let webView = webKitView else { return }
        guard let frame = targetFrame ?? activeAutofillTargetFrame, let handleID = activeAutofillHandleID else {
            // Reject fill closed if frame target or handle is missing or invalidated
            invalidateAutofillFocusTarget()
            return
        }
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else {
            invalidateAutofillFocusTarget()
            return
        }
        let expectedOrigin = Self.canonicalOrigin(
            protocol: origin.protocol,
            host: origin.host,
            port: origin.port
        )

        try await session.fill(
            identity,
            expectedNavigationGeneration: navigationGeneration,
            expectedOrigin: expectedOrigin,
            expectedFrameHandleID: handleID
        ) { body, arguments in
            return try await webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: frame,
                contentWorld: BrowserAutofillContentBridge.contentWorld
            )
        }
        invalidateAutofillFocusTarget()
    }
}
