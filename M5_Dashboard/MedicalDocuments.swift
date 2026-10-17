import Foundation
import CoreData
import PDFKit
import UIKit
import ImageIO

struct MedicalDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var petID: UUID
    var title: String
    var fileName: String
    var documentDate = Date()
    var hospital = ""
    var notes = ""
    var recordID: UUID?
    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100 { return "资料标题需为1–100字。" }
        if hospital.count > 200 || notes.count > 20_000 { return "医院最多200字，备注最多20,000字。" }
        if !ReminderRecurrence.isSupportedDate(documentDate) { return "请选择有效的资料日期。" }
        if !MedicalDocumentImporter.isValidFileName(fileName) { return "资料文件名无效。" }
        return nil
    }
}

struct PreparedMedicalDocument {
    let fileName: String
    let byteCount: Int
}

enum MedicalDocumentError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

enum MedicalDocumentImporter {
    static let maxPDFBytes = 20 * 1024 * 1024
    static let maxPDFPages = 200
    static func isValidFileName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return !name.contains("/") && !name.contains("\\") && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && ["pdf", "jpg", "png"].contains(url.pathExtension)
    }
    /// Also used by full-backup validation; encrypted PDFs are rejected even if unlocked.
    static func validatePDF(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maxPDFBytes else { throw MedicalDocumentError.invalid("PDF 每份最多20 MiB。") }
        guard let document = PDFDocument(data: data), !document.isEncrypted, !document.isLocked,
              (1...maxPDFPages).contains(document.pageCount),
              (0..<document.pageCount).allSatisfy({ document.page(at: $0) != nil }) else {
            throw MedicalDocumentError.invalid("PDF 无法读取、已加密或超过200页，请选择未加密的有效文件。")
        }
    }
    static func prepare(data: Data, fileExtension: String, directory: URL = AvatarStore.directory) throws -> PreparedMedicalDocument {
        let ext = fileExtension.lowercased()
        let output: Data, suffix: String
        if ext == "pdf" {
            try validatePDF(data); output = data; suffix = "pdf"
        } else {
            guard ["jpg", "jpeg", "png"].contains(ext), !data.isEmpty, data.count <= PortableBackup.maxImageBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= PortableBackup.maxImageDimension, height <= PortableBackup.maxImageDimension,
                  width * height <= PortableBackup.maxImagePixels,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else {
                throw MedicalDocumentError.invalid("请选择10 MiB以内的 JPEG/PNG 图片，尺寸最多4096像素、总计1600万像素。")
            }
            let image = UIImage(cgImage: cgImage)
            suffix = type == "public.png" ? "png" : "jpg"
            guard let normalized = suffix == "png" ? image.pngData() : image.jpegData(compressionQuality: 0.9), normalized.count <= PortableBackup.maxImageBytes else {
                throw MedicalDocumentError.invalid("图片归一化后超过10 MiB，请压缩后重试。")
            }
            output = normalized
        }
        try Task.checkCancellation()
        let name = UUID().uuidString + "." + suffix
        let url = directory.appendingPathComponent(name)
        do {
            try output.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return PreparedMedicalDocument(fileName: name, byteCount: output.count)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    static func prepare(from source: URL, directory: URL = AvatarStore.directory) async throws -> PreparedMedicalDocument {
        let worker = Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var result: Result<PreparedMedicalDocument, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    let limit = coordinated.pathExtension.lowercased() == "pdf" ? maxPDFBytes : PortableBackup.maxImageBytes
                    guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= limit else { throw MedicalDocumentError.invalid("文件为空、不是普通文件或超过大小限制。") }
                    let handle = try FileHandle(forReadingFrom: coordinated)
                    defer { try? handle.close() }
                    var bytes = Data()
                    while bytes.count <= limit {
                        try Task.checkCancellation()
                        guard let chunk = try handle.read(upToCount: min(65_536, limit + 1 - bytes.count)), !chunk.isEmpty else { break }
                        bytes.append(chunk)
                    }
                    guard bytes.count <= limit else { throw MedicalDocumentError.invalid("文件超过大小限制。") }
                    return try prepare(data: bytes, fileExtension: source.pathExtension, directory: directory)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw MedicalDocumentError.invalid("文件暂时无法读取，请重新选择。") }
            return try result.get()
        }
        return try await withTaskCancellationHandler(operation: {
            let prepared = try await worker.value
            if Task.isCancelled { discard(prepared, directory: directory); throw CancellationError() }
            return prepared
        }, onCancel: { worker.cancel() })
    }
    static func discard(_ prepared: PreparedMedicalDocument, directory: URL = AvatarStore.directory) {
        guard isValidFileName(prepared.fileName) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(prepared.fileName))
    }
}

final class MedicalDocumentRepository {
    private let store: CareItemStore
    let directory: URL
    init(store: CareItemStore = CareItemStore(), directory: URL = AvatarStore.directory) { self.store = store; self.directory = directory }
    func documents(petID: UUID) throws -> [MedicalDocument] {
        let values = try store.items(MedicalDocument.self, category: .medicalDocument, petID: petID)
        if let error = values.compactMap(\.validationError).first { throw MedicalDocumentError.invalid(error) }
        return values.sorted { $0.documentDate > $1.documentDate }
    }
    func create(_ value: MedicalDocument, prepared: PreparedMedicalDocument) throws {
        do {
            guard value.fileName == prepared.fileName, !(try documents(petID: value.petID)).contains(where: { $0.id == value.id }),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(prepared.fileName).path) else { throw CareItemError.invalidPayload }
            try validate(value)
            try store.upsert(value, id: value.id, petID: value.petID, category: .medicalDocument)
        } catch { MedicalDocumentImporter.discard(prepared, directory: directory); throw error }
    }
    func update(_ value: MedicalDocument, petID: UUID) throws {
        guard value.petID == petID, let existing = try documents(petID: petID).first(where: { $0.id == value.id }), existing.fileName == value.fileName else { throw CareItemError.wrongOwner }
        try validate(value)
        try store.upsert(value, id: value.id, petID: petID, category: .medicalDocument)
    }
    func delete(_ value: MedicalDocument, petID: UUID) throws {
        guard value.petID == petID, let existing = try documents(petID: petID).first(where: { $0.id == value.id }) else { throw CareItemError.wrongOwner }
        try store.delete(id: existing.id)
        if MedicalDocumentImporter.isValidFileName(existing.fileName) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(existing.fileName)) }
    }
    private func validate(_ value: MedicalDocument) throws {
        if let error = value.validationError { throw MedicalDocumentError.invalid(error) }
        if let recordID = value.recordID {
            let request = CDRecord.fetchRequest(); request.predicate = NSPredicate(format: "id == %@ AND petID == %@", recordID as CVarArg, value.petID as CVarArg)
            guard let record = try store.stack.container.viewContext.fetch(request).first,
                  MedicalReport.healthKinds.contains(where: { $0.rawValue == record.kind }) else { throw MedicalDocumentError.invalid("关联记录已不存在，或不是这只宠物的健康记录。") }
        }
    }
}
