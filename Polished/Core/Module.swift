//
//  Module.swift
//  Polished
//
//  Created by Jack Li on 18/6/2026.
//

protocol Module: AnyObject {
    var id: String { get }
    var name: String { get }
    var isEnabled: Bool { get set }
    func start()
    func stop()
}
