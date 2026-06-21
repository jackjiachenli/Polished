//
//  WindowMRU.swift
//  Polished
//

import AppKit
import Foundation

final class WindowMRU {
    private(set) var orderedWindowIDs: [CGWindowID] = []
    private var focusDebounceWorkItem: DispatchWorkItem?

    func recordFocus(windowID: CGWindowID) {
        guard windowID != 0 else { return }
        orderedWindowIDs.removeAll { $0 == windowID }
        orderedWindowIDs.insert(windowID, at: 0)
    }

    func orderedWindows(from available: [SwitchableWindow]) -> [SwitchableWindow] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.windowID, $0) })
        var ordered: [SwitchableWindow] = []
        var seen = Set<CGWindowID>()

        for windowID in orderedWindowIDs {
            guard let window = byID[windowID], seen.insert(windowID).inserted else { continue }
            ordered.append(window)
        }

        for window in available where !seen.contains(window.windowID) {
            ordered.append(window)
            seen.insert(window.windowID)
        }
        return ordered
    }

    func pruneMissing(validWindowIDs: Set<CGWindowID>) {
        orderedWindowIDs.removeAll { !validWindowIDs.contains($0) }
    }

    func scheduleFocusUpdate(debounceInterval: TimeInterval = 0.15, handler: @escaping () -> Void) {
        focusDebounceWorkItem?.cancel()
        let work = DispatchWorkItem(block: handler)
        focusDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func cancelPendingFocusUpdate() {
        focusDebounceWorkItem?.cancel()
        focusDebounceWorkItem = nil
    }
}
