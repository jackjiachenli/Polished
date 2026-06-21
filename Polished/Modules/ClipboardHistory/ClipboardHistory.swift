//
//  ClipboardHistory.swift
//  Polished
//
// Polls NSPasteboard.general for changes and keeps a rolling history.
// Pick via global hotkey (default ⌘⇧V). Selecting an item writes it back to the
// pasteboard and simulates Cmd+V (requires Accessibility permission).
//

import AppKit
import ApplicationServices
import Carbon
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

    private static let pollIntervalIdle: TimeInterval = 1.0
    private static let pollIntervalActive: TimeInterval = 0.1
    private static let activePollBurstCount = 15

    private var pollTimer: Timer?
    private var lastChangeCount = 0
    private var activePollsRemaining = 0
    private var isInternalWrite = false
    private var globalHotkey: GlobalHotkey?
    private var pickerPanel: ClipboardPickerPanel?
    private var saveWorkItem: DispatchWorkItem?

    init() {
        maxItems = UserDefaults.standard.object(forKey: Self.maxItemsKey) as? Int ?? 25
        ignoreConcealed = UserDefaults.standard.object(forKey: Self.ignoreConcealedKey) as? Bool ?? true
        ignoreSensitiveApps = UserDefaults.standard.object(forKey: Self.ignoreSensitiveAppsKey) as? Bool ?? true
        useGlobalHotkey = UserDefaults.standard.object(forKey: Self.useGlobalHotkeyKey) as? Bool ?? true
        persistHistory = UserDefaults.standard.object(forKey: Self.persistHistoryKey) as? Bool ?? true
        hotkeyBinding = Self.loadHotkeyBinding()
    }

    func start() {
        guard AXIsProcessTrusted() else {
            print("ClipboardHistory: Accessibility permission not granted — enable in System Settings")
            return
        }
        guard pollTimer == nil else { return }

        loadPersistedHistoryIfNeeded()
        lastChangeCount = NSPasteboard.general.changeCount
        activePollsRemaining = 0
        pollPasteboard()
        updateHotkeyRegistration()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        activePollsRemaining = 0
        globalHotkey?.unregister()
        globalHotkey = nil
        pickerPanel?.dismiss()
        pickerPanel = nil
        items.removeAll()
        selectedItemID = nil
    }

    private func loadPersistedHistoryIfNeeded() {
        guard persistHistory, items.isEmpty else { return }
        items = ClipboardHistoryStore.load()
        trimToMaxItems()
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
        let panel = pickerPanel ?? ClipboardPickerPanel()
        pickerPanel = panel
        if panel.isVisible {
            panel.dismiss()
        } else {
            pollPasteboard()
            panel.show(history: self)
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

    func pasteSelectedPickerItem(activating target: NSRunningApplication? = nil) {
        guard let id = selectedItemID,
              let item = items.first(where: { $0.id == id }) else { return }
        paste(item, activating: target)
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

    func paste(_ item: ClipboardItem, activating target: NSRunningApplication? = nil) {
        guard AXIsProcessTrusted() else { return }

        isInternalWrite = true
        writeToPasteboard(item.content)
        lastChangeCount = NSPasteboard.general.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let target {
                target.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                KeySimulation.postCommandKey(CGKeyCode(kVK_ANSI_V))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isInternalWrite = false
        }
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        isInternalWrite = true
        writeToPasteboard(item.content)
        lastChangeCount = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
        var pasteboardChanged = false
        defer { scheduleNextPoll(afterChange: pasteboardChanged) }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }

        pasteboardChanged = true
        lastChangeCount = pasteboard.changeCount
        guard !isInternalWrite else { return }

        guard let content = readContent(from: pasteboard) else { return }
        guard !shouldIgnoreCapture(from: pasteboard) else { return }
        guard !isDuplicate(content) else { return }

        items.insert(ClipboardItem(content: content), at: 0)
        trimToMaxItems()
        scheduleSave()
    }

    private func scheduleNextPoll(afterChange: Bool) {
        pollTimer?.invalidate()
        if afterChange {
            activePollsRemaining = Self.activePollBurstCount
        } else if activePollsRemaining > 0 {
            activePollsRemaining -= 1
        }

        let interval = activePollsRemaining > 0 ? Self.pollIntervalActive : Self.pollIntervalIdle
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func shouldIgnoreCapture(from pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        let hasConcealed = types.contains(Self.concealedType)
        let hasTransient = types.contains(Self.transientType)
        let hasSensitiveMarkers = hasConcealed || hasTransient
        let fromSensitiveApp = isSensitiveFrontmostApp()

        // Password managers mark copies with Concealed/Transient; also block while that app is frontmost.
        if ignoreSensitiveApps, fromSensitiveApp || hasSensitiveMarkers {
            return true
        }

        if ignoreConcealed, hasSensitiveMarkers {
            return true
        }

        return false
    }

    private func isSensitiveFrontmostApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.sensitiveBundleIDs.contains(bundleID)
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        let fileURLs = PasteboardFileURLs.fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let image = ClipboardImageStorage.content(from: pasteboard) {
            return .image(image.data, width: image.width, height: image.height)
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
            if !ClipboardImageStorage.write(data: data, to: pasteboard) {
                print("ClipboardHistory: Failed to write image to pasteboard")
            }
        case .fileURLs(let urls):
            let items = urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.path, forType: .fileURL)
                item.setString(url.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

}
