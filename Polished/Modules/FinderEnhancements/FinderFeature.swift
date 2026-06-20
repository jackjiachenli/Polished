//
//  FinderFeature.swift
//  Polished
//

import Foundation

protocol FinderFeature: AnyObject {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var isEnabled: Bool { get set }
    func start()
    func stop()
}
