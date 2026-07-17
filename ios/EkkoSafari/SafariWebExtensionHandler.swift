import SafariServices

// Safari calls this when the web extension sends a native message. Ekko's extension is entirely
// self-contained (all crypto runs in the extension's own JS, exactly as it does in Chrome), so
// there is nothing native to answer — but Safari waits for a reply, so we send an empty one.
//
// ponytail: no native bridge. If the Safari build ever needs to share the app's vault, this is
// where that conversation would start.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [NSExtensionItem()], completionHandler: nil)
    }
}
