//
//  SwitcherEventTap.swift
//  Polished
//

import AppKit
import ApplicationServices
import Carbon

protocol SwitcherEventTapDelegate: AnyObject {
    var isSwitcherOverlayOpen: Bool { get }
    func switcherEventTapDidOpenOverlay()
    func switcherEventTapDidAdvanceSelection()
    func switcherEventTapDidConfirmSelection()
    func switcherEventTapDidCancel()
}

final class SwitcherEventTap {
    weak var delegate: SwitcherEventTapDelegate?
    private(set) var binding: HotkeyBinding

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(binding: HotkeyBinding) {
        self.binding = binding
    }

    func updateBinding(_ binding: HotkeyBinding) {
        self.binding = binding
    }

    func start() {
        guard AXIsProcessTrusted() else {
            print("SwitcherEventTap: Accessibility permission not granted — enable in System Settings")
            return
        }
        guard eventTap == nil else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: switcherEventTapCallback,
            userInfo: refcon
        ) else {
            print("SwitcherEventTap: Failed to create event tap — enable Input Monitoring for Polished, then quit and relaunch")
            _ = CGRequestListenEventAccess()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        PolishedLog.debug("SwitcherEventTap: Event tap active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    fileprivate func handleKeyDownFromTap(_ event: CGEvent) -> CGEvent? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if keyCode == CGKeyCode(kVK_Escape) {
            guard delegate?.isSwitcherOverlayOpen == true else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherEventTapDidCancel()
            }
            return nil
        }

        guard keyCode == CGKeyCode(binding.keyCode) else { return event }
        guard binding.matchesCycleKey(flags: flags) else { return event }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }

        if delegate?.isSwitcherOverlayOpen == true {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherEventTapDidAdvanceSelection()
            }
            return nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.switcherEventTapDidOpenOverlay()
        }
        return nil
    }

    fileprivate func handleFlagsChangedFromTap(_ event: CGEvent) -> CGEvent? {
        guard delegate?.isSwitcherOverlayOpen == true else { return event }
        guard !binding.bindingModifiersStillHeld(event.flags) else { return event }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.switcherEventTapDidConfirmSelection()
        }
        return nil
    }
}

private func switcherEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let switcherTap = Unmanaged<SwitcherEventTap>.fromOpaque(refcon).takeUnretainedValue()
        if let port = switcherTap.eventTapPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let switcherTap = Unmanaged<SwitcherEventTap>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .keyDown:
        if let modified = switcherTap.handleKeyDownFromTap(event) {
            return Unmanaged.passUnretained(modified)
        }
        return nil
    case .flagsChanged:
        if let modified = switcherTap.handleFlagsChangedFromTap(event) {
            return Unmanaged.passUnretained(modified)
        }
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}

private extension SwitcherEventTap {
    var eventTapPort: CFMachPort? { eventTap }
}

private extension HotkeyBinding {
    var requiredCGEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        return flags
    }

    static let nonBindingModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn, .maskHelp,
    ]

    func matchesCycleKey(flags: CGEventFlags) -> Bool {
        let required = requiredCGEventFlags
        guard flags.contains(required) else { return false }
        return flags.intersection(Self.nonBindingModifiers) == required
    }

    func bindingModifiersStillHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(requiredCGEventFlags)
    }
}
