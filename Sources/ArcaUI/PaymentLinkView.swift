#if canImport(UIKit) && canImport(SafariServices)
import SwiftUI
import SafariServices

/// Wraps SFSafariViewController for presenting payment link pages in-app.
public struct PaymentLinkView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (() -> Void)?

    public init(url: URL, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.delegate = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    public class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onDismiss: (() -> Void)?

        init(onDismiss: (() -> Void)?) {
            self.onDismiss = onDismiss
        }

        public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss?()
        }
    }
}

extension View {
    /// Presents a payment link in an in-app Safari browser sheet.
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
