//
//  Module.swift
//  Polished
//

protocol Module: AnyObject {
    var id: String { get }
    var name: String { get }
    var isEnabled: Bool { get set }
    func start()
    func stop()
}
