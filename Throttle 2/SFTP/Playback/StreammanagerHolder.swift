//
//  to.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 31/3/2025.
//


import Foundation

// Simple holder class to keep FFmpegStreamManager instances alive
class FFmpegStreamManagerHolder {
    static let shared = FFmpegStreamManagerHolder()
    
    private var activeManagers: [String: FFmpegStreamManager] = [:]
    
    private init() {}
    
    func storeManager(_ manager: FFmpegStreamManager, withIdentifier identifier: String) {
        activeManagers[identifier] = manager
        print("FFmpegStreamManagerHolder: Stored manager with ID \(identifier)")
    }
    
    func getManager(withIdentifier identifier: String) -> FFmpegStreamManager? {
        return activeManagers[identifier]
    }
    
    func removeManager(withIdentifier identifier: String) {
        if let manager = activeManagers[identifier] {
            manager.stop()
            activeManagers.removeValue(forKey: identifier)
            print("FFmpegStreamManagerHolder: Removed manager with ID \(identifier)")
        }
    }
    
    func tearDownAllManagers() {
        for (identifier, manager) in activeManagers {
            print("FFmpegStreamManagerHolder: Stopping manager with ID \(identifier)")
            manager.stop()
        }
        
        activeManagers.removeAll()
        print("FFmpegStreamManagerHolder: All managers have been torn down")
    }
}