//
//  FileItem.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 4/3/2025.
//

import Foundation
// MARK: - Model
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int?
    let modificationDate: Date

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        return lhs.url == rhs.url && lhs.name == rhs.name
    }
}
