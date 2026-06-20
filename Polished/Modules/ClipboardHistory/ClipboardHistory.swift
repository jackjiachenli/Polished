//
//  ClipboardHistory.swift
//  Polished
//
//  Polls NSPasteboard.general for changes and keeps a rolling history.
//  Pick via global hotkey (default ⌘⇧V). Selecting an item writes it back to the
//  pasteboard and simulates Cmd+V (requires Accessibility permission).
//

import AppKit
import ApplicationServices
import Observation

// MARK: - Clipboard item model

enum ClipboardContent: Equatable {
    case text(String)
    case image(Data, width: Int, height: Int)
    case fileURLs([URL])

    var preview: String {
        switch self {
        case .text(let string):
            let collapsed = string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if collapsed.count <= 60 { return collapsed }
            return String(collapsed.prefix(57)) + "…"
        case .image(_, let width, let height):
            return "Image (\(width)×\(height))"
        case .fileURLs(let urls):
            if urls.count == 1 {
                return urls[0].lastPathComponent
            }
            return "\(urls.count) files"
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let content: ClipboardContent
    let capturedAt: Date

    init(content: ClipboardContent) {
        self.id = UUID()
        self.content = content
        self.capturedAt = Date()
    }

    init(id: UUID, content: ClipboardContent, capturedAt: Date) {
        self.id = id
        self.content = content
        self.capturedAt = capturedAt
    }
}

// MARK: - ClipboardHistory module

@Observable
final class ClipboardHistory: Module {
    let id = "clipboard-history"
    var name = "Clipboard History"
    var isEnabled = false

    var hotkeyBinding: HotkeyBinding {
        didSet {
            guard hotkeyBinding != oldValue else { return }
            saveHotkeyBinding()
            if isEnabled {
                updateHotkeyRegistration()
            }
        }
    }

    var hotkeyDisplayString: String { hotkeyBinding.displayString }

    private(set) var items: [ClipboardItem] = []
    var selectedItemID: UUID?

    var maxItems: Int {
        didSet {
            let clamped = min(max(maxItems, 5), 100)
            if maxItems != clamped { maxItems = clamped }
            UserDefaults.standard.set(maxItems, forKey: Self.maxItemsKey)
            trimToMaxItems()
            scheduleSave()
        }
    }

    var ignoreConcealed: Bool {
        didSet {
            UserDefaults.standard.set(ignoreConcealed, forKey: Self.ignoreConcealedKey)
        }
    }

    var ignoreSensitiveApps: Bool {
        didSet {
            UserDefaults.standard.set(ignoreSensitiveApps, forKey: Self.ignoreSensitiveAppsKey)
        }
    }

    var useGlobalHotkey: Bool {
        didSet {
            UserDefaults.standard.set(useGlobalHotkey, forKey: Self.useGlobalHotkeyKey)
            if isEnabled {
                updateHotkeyRegistration()
            }
        }
    }

    var persistHistory: Bool {
        didSet {
            UserDefaults.standard.set(persistHistory, forKey: Self.persistHistoryKey)
            if persistHistory {
                scheduleSave()
            } else {
                ClipboardHistoryStore.clear()
            }
        }
    }

    private static let maxItemsKey = "clipboardHistory.maxItems"
    private static let ignoreConcealedKey = "clipboardHistory.ignoreConcealed"
    private static let ignoreSensitiveAppsKey = "clipboardHistory.ignoreSensitiveApps"
    private static let useGlobalHotkeyKey = "clipboardHistory.useGlobalHotkey"
    private static let persistHistoryKey = "clipboardHistory.persistHistory"
    private static let hotkeyKeyCodeKey = "clipboardHistory.hotkeyKeyCode"
    private static let hotkeyModifiersKey = "clipboardHistory.hotkeyModifiers"

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private static let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
    ]

    private var pollTimer: Timer?
    private var lastChangeCount = 0
    private var isInternalWrite = false
    private var globalHotkey: GlobalHotkey?
    private let pickerPanel = ClipboardPickerPanel()
    private var saveWorkItem: DispatchWorkItem?

    init() {
        maxItems = UserDefaults.standard.object(forKey: Self.maxItemsKey) as? Int ?? 25
        ignoreConcealed = UserDefaults.standard.object(forKey: Self.ignoreConcealedKey) as? Bool ?? true
        ignoreSensitiveApps = UserDefaults.standard.object(forKey: Self.ignoreSensitiveAppsKey) as? Bool ?? true
        useGlobalHotkey = UserDefaults.standard.object(forKey: Self.useGlobalHotkeyKey) as? Bool ?? true
        persistHistory = UserDefaults.standard.object(forKey: Self.persistHistoryKey) as? Bool ?? true
        hotkeyBinding = Self.loadHotkeyBinding()

        if persistHistory {
            items = ClipboardHistoryStore.load()
            trimToMaxItems()
        }
    }

    func start() {
        guard AXIsProcessTrusted() else {
            print("ClipboardHistory: Accessibility permission not granted — enable in System Settings")
            return
        }
        guard pollTimer == nil else { return }

        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        updateHotkeyRegistration()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        globalHotkey?.unregister()
        globalHotkey = nil
        if pickerPanel.isVisible {
            pickerPanel.dismiss()
        }
    }

    func clearHistory() {
        items.removeAll()
        selectedItemID = nil
        ClipboardHistoryStore.clear()
    }

    func deleteItem(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        deleteItem(at: index)
    }

    func deleteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        clampSelection()
        if items.isEmpty {
            ClipboardHistoryStore.clear()
        } else {
            scheduleSave()
        }
    }

    func deleteSelectedItem() {
        guard let id = selectedItemID,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteItem(at: index)
    }

    func togglePicker() {
        if pickerPanel.isVisible {
            pickerPanel.dismiss()
        } else {
            pickerPanel.show(history: self)
        }
    }

    func resetPickerSelection() {
        selectedItemID = items.first?.id
    }

    func movePickerSelection(delta: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) ?? 0
        let next = min(max(currentIndex + delta, 0), items.count - 1)
        selectedItemID = items[next].id
    }

    func pasteSelectedPickerItem() {
        guard let id = selectedItemID,
              let item = items.first(where: { $0.id == id }) else { return }
        paste(item)
    }

    private func clampSelection() {
        if items.isEmpty {
            selectedItemID = nil
        } else if let id = selectedItemID, items.contains(where: { $0.id == id }) {
            // keep current selection
        } else {
            selectedItemID = items.first?.id
        }
    }

    func paste(_ item: ClipboardItem) {
        guard AXIsProcessTrusted() else { return }

        isInternalWrite = true
        writeToPasteboard(item.content)
        lastChangeCount = NSPasteboard.general.changeCount
        simulateCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isInternalWrite = false
        }
    }

    // MARK: - Hotkey

    private func updateHotkeyRegistration() {
        globalHotkey?.unregister()
        globalHotkey = nil

        guard useGlobalHotkey else { return }

        let hotkey = GlobalHotkey { [weak self] in
            self?.togglePicker()
        }
        hotkey.register(
            keyCode: hotkeyBinding.keyCode,
            modifiers: hotkeyBinding.carbonModifiers
        )
        globalHotkey = hotkey
    }

    private static func loadHotkeyBinding() -> HotkeyBinding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: hotkeyKeyCodeKey) != nil,
              defaults.object(forKey: hotkeyModifiersKey) != nil else {
            return .clipboardDefault
        }
        let binding = HotkeyBinding(
            keyCode: UInt32(defaults.integer(forKey: hotkeyKeyCodeKey)),
            carbonModifiers: UInt32(defaults.integer(forKey: hotkeyModifiersKey))
        )
        return binding.isValid ? binding : .clipboardDefault
    }

    private func saveHotkeyBinding() {
        UserDefaults.standard.set(Int(hotkeyBinding.keyCode), forKey: Self.hotkeyKeyCodeKey)
        UserDefaults.standard.set(Int(hotkeyBinding.carbonModifiers), forKey: Self.hotkeyModifiersKey)
    }

    // MARK: - Pasteboard polling

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isInternalWrite else { return }

        guard let content = readContent(from: pasteboard) else { return }
        guard !shouldIgnoreCapture(from: pasteboard) else { return }
        guard !isDuplicate(content) else { return }

        items.insert(ClipboardItem(content: content), at: 0)
        trimToMaxItems()
        scheduleSave()
    }

    private func shouldIgnoreCapture(from pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])

        if types.contains(Self.transientType) {
            return true
        }

        if ignoreConcealed, types.contains(Self.concealedType) {
            return true
        }

        if ignoreSensitiveApps,
           let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.sensitiveBundleIDs.contains(bundleID) {
            return true
        }

        return false
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            return .fileURLs(urls)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let width = max(Int(bitmap.pixelsWide), 1)
            let height = max(Int(bitmap.pixelsHigh), 1)
            return .image(png, width: width, height: height)
        }

        if let string = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            return .text(string)
        }

        return nil
    }

    private func isDuplicate(_ content: ClipboardContent) -> Bool {
        items.first?.content == content
    }

    private func trimToMaxItems() {
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
            clampSelection()
        }
    }

    private func scheduleSave() {
        guard persistHistory else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            ClipboardHistoryStore.save(self.items)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Pasteboard write & key simulation

    private func writeToPasteboard(_ content: ClipboardContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch content {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .image(let data, _, _):
            if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .fileURLs(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
    }

    private func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
