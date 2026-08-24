import CoreGraphics
import Foundation
import IOKit

enum ProductionKeyboardInputMonitoringStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    case restricted
}

struct ProductionKeyboardCapturedEvent: Equatable, Sendable {
    let isPressed: Bool
    let key: KeyboardCapturedKey
    let kind: KeyboardCaptureEventKind
}

enum ProductionKeyboardEventTapMessage: Equatable, Sendable {
    case disabled
    case event(ProductionKeyboardCapturedEvent)
}

protocol ProductionKeyboardEventTapControlling: AnyObject {
    var authorizationStatus: ProductionKeyboardInputMonitoringStatus { get }
    var isInstalled: Bool { get }

    func requestAuthorization() -> ProductionKeyboardInputMonitoringStatus
    func install(
        handler: @escaping @Sendable (ProductionKeyboardEventTapMessage) -> Void
    ) -> Bool
    func setCaptureActive(_ active: Bool)
    func invalidate()
}

final class ProductionKeyboardEventTap:
    ProductionKeyboardEventTapControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var captureActive = false
    private var handler: (@Sendable (ProductionKeyboardEventTapMessage) -> Void)?
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var authorizationStatus: ProductionKeyboardInputMonitoringStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .authorized
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .notDetermined
        }
    }

    var isInstalled: Bool {
        lock.withLock { port != nil }
    }

    func requestAuthorization() -> ProductionKeyboardInputMonitoringStatus {
        guard authorizationStatus != .authorized else { return .authorized }
        _ = CGRequestListenEventAccess()
        return authorizationStatus
    }

    func install(
        handler: @escaping @Sendable (ProductionKeyboardEventTapMessage) -> Void
    ) -> Bool {
        if lock.withLock({ port != nil }) {
            lock.withLock { self.handler = handler }
            return true
        }
        guard authorizationStatus == .authorized else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: productionKeyboardEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        lock.withLock {
            self.handler = handler
            self.port = port
            self.runLoopSource = source
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func setCaptureActive(_ active: Bool) {
        lock.withLock { captureActive = active }
    }

    func invalidate() {
        let owned = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            captureActive = false
            handler = nil
            defer {
                port = nil
                runLoopSource = nil
            }
            return (port, runLoopSource)
        }
        if let source = owned.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = owned.0 {
            CFMachPortInvalidate(port)
        }
    }

    fileprivate func receive(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let callback = lock.withLock {
                captureActive = false
                return handler
            }
            callback?(.disabled)
            return Unmanaged.passUnretained(event)
        }

        let state = lock.withLock { (captureActive, handler) }
        guard state.0 else { return Unmanaged.passUnretained(event) }
        if let captured = Self.capturedEvent(type: type, event: event) {
            state.1?(.event(captured))
        }
        // Device-first semantics consume even unmappable keyboard events.
        return nil
    }

    private static func capturedEvent(
        type: CGEventType,
        event: CGEvent
    ) -> ProductionKeyboardCapturedEvent? {
        let keyCodeValue = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCodeValue >= 0,
              keyCodeValue <= Int64(UInt16.max),
              let key = ProductionKeyboardHIDUsage.key(
                  forKeyCode: UInt16(keyCodeValue)
              )
        else { return nil }
        let kind: KeyboardCaptureEventKind
        let pressed: Bool
        switch type {
        case .keyDown:
            kind = .keyDown
            pressed = true
        case .keyUp:
            kind = .keyUp
            pressed = false
        case .flagsChanged:
            kind = .flagsChanged
            pressed = ProductionKeyboardHIDUsage.modifierIsPressed(
                keyCode: UInt16(keyCodeValue),
                flags: event.flags
            )
        default:
            return nil
        }
        return ProductionKeyboardCapturedEvent(
            isPressed: pressed,
            key: key,
            kind: kind
        )
    }
}

private func productionKeyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ProductionKeyboardEventTap>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
        .receive(type: type, event: event)
}
