import AppKit
import Darwin
import Foundation

@MainActor
final class ProductionIPAInstallButton: NSButton {
    var acceptedDrop: ((ToolbarInstallParameter) -> Void)?
    var invalidDrop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        do {
            let parameter = try ToolbarDropTarget.resolve(
                candidates: droppedFileURLs(sender.draggingPasteboard).map {
                    ToolbarDropCandidate(
                        path: $0.path,
                        isRegularFile: Self.isRegularFile($0.path)
                    )
                }
            )
            acceptedDrop?(parameter)
            return true
        } catch {
            invalidDrop?()
            return false
        }
    }

    private func droppedFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return values.compactMap { ($0 as? NSURL) as URL? }
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_size > 0
    }
}
