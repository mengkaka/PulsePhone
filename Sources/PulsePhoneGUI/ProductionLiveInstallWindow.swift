import AppKit
import Foundation

/// One destination for the entire window, including native toolbar chrome.
/// No child view registers file drops, so moving over controls keeps the same destination.
@MainActor
final class ProductionLiveInstallWindow: NSWindow, NSDraggingDestination {
    var acceptsInstallDrop: (() -> Bool)?
    var acceptedDrop: ((ToolbarInstallParameter) -> Void)?

    private var borderView: ProductionInstallDropBorderView?
    private var consumedSequenceNumber: Int?

    var isInstallDropHighlighted: Bool {
        borderView?.isHidden == false
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        registerForDraggedTypes([.fileURL])
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearInstallDropHighlight()
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        clearInstallDropHighlight()
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearInstallDropHighlight()
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let valid = installParameter(sender) != nil
        if !valid { clearInstallDropHighlight() }
        return valid
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        clearInstallDropHighlight()
        guard let parameter = installParameter(sender), let acceptedDrop else { return false }
        // Fence before invoking the callback, including synchronous/reentrant callers.
        consumedSequenceNumber = sender.draggingSequenceNumber
        acceptedDrop(parameter)
        return true
    }

    override func close() {
        clearInstallDropHighlight()
        acceptsInstallDrop = nil
        acceptedDrop = nil
        super.close()
    }

    func clearInstallDropHighlight() {
        borderView?.isHidden = true
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard installParameter(sender) != nil else {
            clearInstallDropHighlight()
            return []
        }
        // Fullscreen can reparent AppKit's frame view. Use the current container.
        guard let container = contentView?.superview else { return [] }
        let border = borderView ?? ProductionInstallDropBorderView(frame: container.bounds)
        borderView = border
        if border.superview !== container {
            border.removeFromSuperview()
            container.addSubview(border, positioned: .above, relativeTo: nil)
        }
        border.frame = container.bounds
        border.isHidden = false
        return .copy
    }

    private func installParameter(_ sender: any NSDraggingInfo) -> ToolbarInstallParameter? {
        guard acceptsInstallDrop?() == true,
              acceptedDrop != nil,
              sender.draggingDestinationWindow === self,
              consumedSequenceNumber != sender.draggingSequenceNumber,
              sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.pasteboardItems?.count == 1
        else { return nil }
        let values = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = values.compactMap { ($0 as? NSURL) as URL? }
        return try? ToolbarDropTarget.resolve(candidates: urls.map {
            let type = ToolbarPicker.nodeTypes($0.path)
            return ToolbarDropCandidate(
                path: $0.path,
                isRegularFile: type.isRegularFile,
                isDirectory: type.isDirectory
            )
        })
    }
}

@MainActor
final class ProductionInstallDropBorderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        path.stroke()
    }
}
