import SwiftUI
import PDFKit

struct DashboardPDFPreview: View {
    let url: URL
    private let document: PDFDocument?
    @Environment(\.dismiss) private var dismiss
    init(url: URL) { self.url = url; document = PDFDocument(url: url) }

    var body: some View {
        NavigationStack {
            if let document {
                VStack(spacing: 0) {
                    Text("\(document.pageCount) 页").font(.caption).padding()
                        .accessibilityIdentifier("dashboard.pdfPageCount")
                    PDFDocumentView(document: document)
                        .accessibilityIdentifier("dashboard.pdfPreview")
                }
                .navigationTitle("成长报告")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("dashboard.sharePDF")
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                }
            } else { Text("报告无法打开，请重新导出。") }
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = document
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) { uiView.document = document }
}
