//
//  FinderEnhancements.swift
//  Polished
//
//  Explorer-like improvements for Finder. Sub-features (Cut, path bar, etc.) are toggled
//  in Settings; the menu bar exposes a single master switch.
//

import Foundation
import Observation

@Observable
final class FinderEnhancements: Module {
    let id = "finder-enhancements"
    var name = "Finder Enhancements"
    var isEnabled = false

    private let cutFeature = FinderCutFeature()

    private var features: [FinderFeature] {
        [cutFeature]
    }

    private static let cutEnabledKey = "finderEnhancements.cut.enabled"

    var cutEnabled: Bool {
        didSet {
            guard cutEnabled != oldValue else { return }
            cutFeature.isEnabled = cutEnabled
            UserDefaults.standard.set(cutEnabled, forKey: Self.cutEnabledKey)
            syncFeatures()
        }
    }

    init() {
        cutEnabled = UserDefaults.standard.object(forKey: Self.cutEnabledKey) as? Bool ?? true
        cutFeature.isEnabled = cutEnabled
    }

    func start() {
        syncFeatures()
    }

    func stop() {
        for feature in features {
            feature.stop()
        }
    }

    private func syncFeatures() {
        for feature in features {
            if isEnabled, feature.isEnabled {
                feature.start()
            } else {
                feature.stop()
            }
        }
    }
}
