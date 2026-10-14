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
                    let type = ToolbarPicker.nodeTypes($0.path)
                    return ToolbarDropCandidate(
                        path: $0.path,
                        isRegularFile: type.isRegularFile,
                        isDirectory: type.isDirectory
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

}
