//
//  PolishedLog.swift
//  Polished
//

import Foundation

enum PolishedLog {
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}
