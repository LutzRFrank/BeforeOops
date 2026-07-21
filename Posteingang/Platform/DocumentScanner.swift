#if os(iOS)
import PDFKit
import SwiftUI
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: (URL) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (URL) -> Void
        let onCancel: () -> Void
        let onError: (Error) -> Void

        init(onScan: @escaping (URL) -> Void, onCancel: @escaping () -> Void, onError: @escaping (Error) -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onError(error)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pdf = PDFDocument()
            for index in 0..<scan.pageCount {
                if let page = PDFPage(image: scan.imageOfPage(at: index)) {
                    pdf.insert(page, at: index)
                }
            }

            let url = FileManager.default.temporaryDirectory
                .appending(path: "Scan-\(UUID().uuidString).pdf")
            if pdf.write(to: url) {
                onScan(url)
            } else {
                onError(DocumentStoreError.unreadableFile)
            }
        }
    }
}
#endif
