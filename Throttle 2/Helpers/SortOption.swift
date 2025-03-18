import Foundation
import SwiftUI

enum SortOption: String, CaseIterable {
    case name = "name"
    case activity = "activity"
    case dateAdded = "dateAdded"
    
    static func saveToDefaults(_ option: SortOption) {
        UserDefaults.standard.set(option.rawValue, forKey: "sortOption")
    }
    
    static func loadFromDefaults() -> SortOption {
        if let savedValue = UserDefaults.standard.string(forKey: "sortOption"),
           let option = SortOption(rawValue: savedValue) {
            return option
        }
        return .dateAdded
    }
}