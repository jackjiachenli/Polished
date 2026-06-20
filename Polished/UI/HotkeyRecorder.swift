//
//  HotkeyRecorder.swift
//  Polished
//

import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var binding: HotkeyBinding
    var defaultBinding: HotkeyBinding = .clipboardDefault

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press shortcut…" : binding.displayString)
                    .frame(minWidth: 88, alignment: .center)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press a key combination. Esc to cancel." : "Click to change shortcut")

            Button("Reset") {
                binding = defaultBinding
            }
            .disabled(binding == defaultBinding)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if let recorded = HotkeyBinding.from(event: event), recorded.isValid {
                binding = recorded
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
