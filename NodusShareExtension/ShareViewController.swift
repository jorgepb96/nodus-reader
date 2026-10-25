// SPDX-License-Identifier: AGPL-3.0-only
import DesignSystem
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Attachments

enum AttachmentKind: Sendable {
    case file(UTType)
    case text(UTType)
    case webURL
    case fileURL
}

struct ShareAttachment: Identifiable {
    let id = UUID()
    let provider: NSItemProvider
    let name: String
    let kind: AttachmentKind
    let type: UTType
}

// MARK: - Model

@MainActor
@Observable
final class ShareImportModel {
    let context: NSExtensionContext?

    var attachments: [ShareAttachment] = []
    var collections: [SharedCollection] = []
    var destinationID: UUID?
    var isLoading = true
    var isImporting = false
    var progressText = ""
    var errorMessage: String?
    var appGroupAvailable = SharedImportInbox.defaultRoot != nil
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() async {
        collections = SharedImportInbox.collections()
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        var found: [ShareAttachment] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if let attachment = attachment(for: provider) {
                    found.append(attachment)
                }
            }
        }

        attachments = found
        isLoading = false
        if !appGroupAvailable {
            errorMessage = SharedInboxError.appGroupUnavailable.errorDescription
        } else if found.isEmpty {
            errorMessage = String(localized: "No supported document was found in the shared items.")
        }
    }

    private func attachment(for provider: NSItemProvider) -> ShareAttachment? {
        let fileTypes: [UTType] = [.pdf, .epub, .rtf, .html, .plainText, markdownType].compactMap { $0 }
        for type in fileTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let name = displayName(for: provider, type: type)
            return ShareAttachment(provider: provider, name: name,
                                   kind: .file(type), type: type)
        }
        // `public.file-url` conforms to `public.url`; test the more specific
        // type first so it takes the security-scoped file path, not HTTP.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return ShareAttachment(provider: provider, name: provider.suggestedName ?? "Document",
                                   kind: .fileURL, type: .fileURL)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return ShareAttachment(provider: provider, name: provider.suggestedName ?? "Web page",
                                   kind: .webURL, type: .url)
        }
        return nil
    }

    private var markdownType: UTType? {
        UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md")
    }

    private func displayName(for provider: NSItemProvider, type: UTType) -> String {
        if let name = provider.suggestedName, !name.isEmpty {
            return ensureExtension(name, type: type)
        }
        return "Document.\(type.preferredFilenameExtension ?? "dat")"
    }

    private func ensureExtension(_ name: String, type: UTType) -> String {
        let ns = name as NSString
        if !ns.pathExtension.isEmpty { return name }
        guard let ext = type.preferredFilenameExtension else { return name }
        return "\(name).\(ext)"
    }

    private func supportedExtension(_ name: String, type: UTType) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let supported = ["epub", "pdf", "txt", "text", "md", "markdown", "html", "htm", "rtf"]
        if supported.contains(ext) { return true }
        return ["epub", "pdf", "rtf", "html", "txt", "md"].contains(type.preferredFilenameExtension ?? "")
    }

    func importItems() async -> Bool {
        guard appGroupAvailable else {
            errorMessage = SharedInboxError.appGroupUnavailable.errorDescription
            return false
        }
        guard !attachments.isEmpty else { return false }
        isImporting = true
        errorMessage = nil
        cancelled = false
        defer { isImporting = false }

        var staged: [SharedImportItem] = []
        for (index, attachment) in attachments.enumerated() {
            if cancelled { break }
            progressText = "Preparing \(attachment.name) (\(index + 1) of \(attachments.count))…"
            do {
                let file = try await materialize(attachment)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                guard cancelled == false else { break }
                let actualName = file.lastPathComponent
                guard supportedExtension(actualName, type: attachment.type) else {
                    throw SharedInboxError.unsupported(actualName)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                guard size <= 250 * 1024 * 1024 else {
                    throw SharedInboxError.unsupported("\(actualName) (larger than 250 MB)")
                }
                let item = try SharedImportInbox.stage(
                    fileURL: file,
                    fileName: actualName,
                    collectionID: destinationID
                )
                staged.append(item)
            } catch {
                for item in staged {
                    SharedImportInbox.remove(item)
                }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return false
            }
        }
        if cancelled {
            for item in staged {
                SharedImportInbox.remove(item)
            }
            return false
        }
        progressText = String(localized: "Ready to import in Nodus Reader.")
        return true
    }

    // MARK: Materialisation

    private func materialize(_ attachment: ShareAttachment) async throws -> URL {
        switch attachment.kind {
        case .file(let type):
            if let file = try? await loadFile(provider: attachment.provider, type: type,
                                              name: attachment.name) {
                return file
            }
            if let text = try? await loadText(provider: attachment.provider, type: type,
                                              name: attachment.name) {
                return text
            }
            throw SharedInboxError.unreadableItem(attachment.name)
        case .text(let type):
            return try await loadText(provider: attachment.provider, type: type, name: attachment.name)
        case .webURL:
            return try await downloadWebPage(provider: attachment.provider, name: attachment.name)
        case .fileURL:
            return try await loadFileURL(provider: attachment.provider, name: attachment.name)
        }
    }

    private func loadFile(provider: NSItemProvider, type: UTType, name: String) async throws -> URL {
        let preferredExtension = type.preferredFilenameExtension
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? SharedInboxError.unreadableItem(name))
                    return
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let rawName = url.lastPathComponent.isEmpty ? name : url.lastPathComponent
                    let fileName: String
                    if (rawName as NSString).pathExtension.isEmpty, let preferredExtension {
                        fileName = "\(rawName).\(preferredExtension)"
                    } else {
                        fileName = rawName
                    }
                    let destination = directory.appendingPathComponent(SharedImportInbox.sanitized(fileName))
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadText(provider: NSItemProvider, type: UTType, name: String) async throws -> URL {
        let value: NSSecureCoding? = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: SharedInboxError.unreadableItem(name)) }
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(SharedImportInbox.sanitized(name))
            if let data = value as? Data {
                try data.write(to: destination, options: .atomic)
            } else if let string = value as? String {
                try string.write(to: destination, atomically: true, encoding: .utf8)
            } else if let url = value as? URL {
                try FileManager.default.copyItem(at: url, to: destination)
            } else {
                throw SharedInboxError.unreadableItem(name)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func loadFileURL(provider: NSItemProvider, name: String) async throws -> URL {
        let value: NSSecureCoding? = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: SharedInboxError.unreadableItem(name)) }
            }
        }
        guard let url = value as? URL else { throw SharedInboxError.unreadableItem(name) }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var copyError: Error?
        let rawName = url.lastPathComponent.isEmpty ? name : url.lastPathComponent
        let fileName = rawName
        let destination = directory.appendingPathComponent(SharedImportInbox.sanitized(fileName))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError {
            try? FileManager.default.removeItem(at: directory)
            throw coordinationError
        }
        if let copyError {
            try? FileManager.default.removeItem(at: directory)
            throw copyError
        }
        return destination
    }

    private func downloadWebPage(provider: NSItemProvider, name: String) async throws -> URL {
        let value: NSSecureCoding? = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: SharedInboxError.unreadableItem(name)) }
            }
        }
        guard let url = value as? URL else { throw SharedInboxError.unreadableItem(name) }
        // Stream to disk: share extensions have a small memory limit, so a
        // large PDF loaded into memory would be killed before the size check.
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SharedInboxError.unsupported("\(url.absoluteString) (HTTP \(http.statusCode))")
        }
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 200 * 1024 * 1024 else {
            throw SharedInboxError.unreadableItem("\(name) (larger than 200 MB)")
        }
        let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
        let ext: String
        switch mime {
        case "application/pdf": ext = "pdf"
        case "application/epub+zip": ext = "epub"
        default: ext = "html"
        }
        let suggested = name.isEmpty ? url.lastPathComponent : name
        let base = (suggested as NSString).deletingPathExtension
        let safeBase = SharedImportInbox.sanitized(base.isEmpty ? (url.host ?? "Web page") : base)
        let fileName = "\(safeBase).\(ext)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(SharedImportInbox.sanitized(fileName))
            try FileManager.default.moveItem(at: downloaded, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

// MARK: - UI

struct ShareImportView: View {
    @Bindable var model: ShareImportModel
    var onFinish: (Bool) -> Void
    private let palette = NodusPalette.dark

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        BrandToolbar()
                        Spacer()
                        Button("Cancel") {
                            model.cancel()
                            onFinish(false)
                        }
                            .font(.subheadline)
                            .foregroundStyle(palette.muted)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Import to Nodus Reader")
                            .font(.system(size: 30, weight: .regular, design: .serif))
                            .foregroundStyle(palette.text)
                        Text("The document stays on this device. Nothing is uploaded.")
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                    }

                    if model.isLoading {
                        ProgressView().tint(palette.accent)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if model.attachments.isEmpty {
                        Text(model.errorMessage ?? String(localized: "No supported documents were shared."))
                            .font(.footnote)
                            .foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.attachments) { attachment in
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(palette.accent)
                                        .frame(width: 34, height: 34)
                                        .background(palette.selection, in: RoundedRectangle(cornerRadius: 9))
                                    Text(attachment.name)
                                        .font(.subheadline)
                                        .foregroundStyle(palette.text)
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 52)
                                if attachment.id != model.attachments.last?.id {
                                    Divider().overlay(palette.line)
                                }
                            }
                        }
                        .panelCard(radius: 18)

                        Menu {
                            Button(String(localized: "Inbox")) { model.destinationID = nil }
                            if !model.collections.isEmpty { Divider() }
                            ForEach(model.collections) { collection in
                                Button(String(repeating: "  ", count: collection.depth) + collection.name) {
                                    model.destinationID = collection.id
                                }
                            }
                        } label: {
                            HStack {
                                Text("Add to")
                                    .foregroundStyle(palette.muted)
                                Text(model.collections.first(where: { $0.id == model.destinationID })?.name ?? String(localized: "Inbox"))
                                    .foregroundStyle(palette.text)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .foregroundStyle(palette.muted)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(palette.panel, in: Capsule())
                            .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                        }
                        .menuIndicator(.hidden)
                    }

                    if let error = model.errorMessage, !model.attachments.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(palette.destructive)
                    }

                    Button {
                        Task {
                            let success = await model.importItems()
                            if success { onFinish(true) }
                        }
                    } label: {
                        Group {
                            if model.isImporting {
                                ProgressView().tint(palette.onAccent)
                            } else {
                                Text("Import")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading || model.isImporting || model.attachments.isEmpty || !model.appGroupAvailable)

                    if model.isImporting {
                        Text(model.progressText)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(20)
            }
        }
        .nodusPalette(palette)
        .preferredColorScheme(.dark)
        .task { await model.load() }
    }
}

// MARK: - Extension controller

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(NodusPalette.dark.background)
        let model = ShareImportModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareImportView(model: model) { [weak self] success in
            self?.finish(success: success)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    private func finish(success: Bool) {
        if success {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            let error = NSError(domain: "ai.nodus.reader.share", code: 0,
                                userInfo: [NSLocalizedDescriptionKey: String(localized: "Import cancelled")])
            extensionContext?.cancelRequest(withError: error)
        }
    }
}
