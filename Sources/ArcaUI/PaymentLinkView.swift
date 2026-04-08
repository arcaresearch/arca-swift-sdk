#if canImport(UIKit) && canImport(WebKit)
import SwiftUI
import WebKit

/// Presents payment link pages in-app using WKWebView.
///
/// Uses `WKUIDelegate.webViewDidClose(_:)` to detect `window.close()` calls
/// from the payment portal (used by `returnStrategy: "close"`).
/// `SFSafariViewController` does not support `window.close()` because it
/// runs in a separate process.
public struct PaymentLinkView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (() -> Void)?

    public init(url: URL, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> PaymentWebViewController {
        let vc = PaymentWebViewController(url: url)
        vc.onDismiss = onDismiss
        return vc
    }

    public func updateUIViewController(_ uiViewController: PaymentWebViewController, context: Context) {}
}

/// UIViewController hosting a WKWebView for payment flows.
/// Handles `window.close()` via WKUIDelegate and basic navigation errors.
public class PaymentWebViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {
    private let url: URL
    var onDismiss: (() -> Void)?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        view.addSubview(webView)

        webView.load(URLRequest(url: url))
    }

    // MARK: - WKUIDelegate

    /// Called when the page executes `window.close()`.
    public func webViewDidClose(_ webView: WKWebView) {
        onDismiss?()
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
    }
}

extension View {
    /// Presents a payment link in an in-app web view sheet.
    ///
    /// The view supports `window.close()` from the payment portal, which
    /// automatically dismisses the sheet when the user completes a deposit
    /// with `returnStrategy: "close"`.
    public func paymentLinkSheet(
        isPresented: Binding<Bool>,
        url: URL,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            PaymentLinkView(url: url, onDismiss: {
                isPresented.wrappedValue = false
                onDismiss?()
            })
            .ignoresSafeArea()
        }
    }
}
#endif
