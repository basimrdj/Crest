import Foundation
import WebKit

// MARK: - Actions - WebKit

extension BrowserAutofillContentBridge {
    static let contentWorld = WKContentWorld.world(name: "com.pauldavis.crest.autofill")

    static func install(
        in userContentController: WKUserContentController,
        receive: @escaping @MainActor (WKScriptMessage) -> Void
    ) -> BrowserScriptMessageProxy {
        let proxy = BrowserScriptMessageProxy(receive: receive)
        userContentController.add(
            proxy,
            contentWorld: contentWorld,
            name: messageHandlerName
        )
        userContentController.addUserScript(
            WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: contentWorld
            )
        )
        return proxy
    }
}
