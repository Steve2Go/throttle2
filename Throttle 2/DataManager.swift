////
////  DataManager.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 1/3/2025.
////
import SwiftUI
import CoreData

//// cloudkit
final class DataManager {
    static let shared = DataManager()
    static var initCount = 0
    // Detect if running in the helper
    private let isHelper = Bundle.main.bundleIdentifier == "com.srgim.ThrottleMountHelper"
    @AppStorage("useCloudKit") var useCloudKit: Bool = false

    let persistentContainer: NSPersistentContainer

    private init() {
        DataManager.initCount += 1
        print("⚠️ DataManager initialized \(DataManager.initCount) times")
        
        if isHelper {
            // Use local store only, no CloudKit
            persistentContainer = NSPersistentContainer(name: "CoreData")
        } else {
            // Use CloudKit in main app
            persistentContainer = NSPersistentCloudKitContainer(name: "CoreData")
        }
        
        // Configure the persistent store description for CloudKit.
        guard let storeDescription = persistentContainer.persistentStoreDescriptions.first else {
            fatalError("No persistent store description found")
        }
        if !isHelper && useCloudKit {
            // Set CloudKit container options to enable syncing.
            storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.srgim.throttle.app")
        } else {
            // Remove CloudKit options to disable syncing.
            storeDescription.cloudKitContainerOptions = nil
        }
        
        // Use the default Application Support directory for Core Data storage
        let fileManager = FileManager.default
        let storeURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CoreData.sqlite")
        storeDescription.url = storeURL
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        
        // Load persistent stores
        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                // Provide more detailed error information
                print("❌ Failed to load Core Data stack:")
                print("   Store URL: \(description.url?.absoluteString ?? "unknown")")
                print("   Error: \(error)")
                print("   CloudKit enabled: \(!self.isHelper && self.useCloudKit)")
                fatalError("Failed to load Core Data stack: \(error)")
            }
            print("✅ Successfully loaded persistent store: \(description)")
            print("📍 Model URL: \(description.url?.absoluteString ?? "unknown")")
        }
        
        // Configure the view context for automatic merging and merge policies.
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("❌ Error saving context: \(error)")
                // Consider adding more sophisticated error handling here
                // For example, you might want to retry, show user notification, etc.
            }
        }
    }
}
