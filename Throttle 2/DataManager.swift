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
    @AppStorage("useCloudKit") var useCloudKit: Bool = true

    let persistentContainer: NSPersistentCloudKitContainer

    private init() {
        DataManager.initCount += 1
        print("⚠️ DataManager initialized \(DataManager.initCount) times")
        
        // Initialize with NSPersistentCloudKitContainer
        persistentContainer = NSPersistentCloudKitContainer(name: "CoreData")
        
        // Configure the persistent store description for CloudKit.
        guard let storeDescription = persistentContainer.persistentStoreDescriptions.first else {
            fatalError("No persistent store description found")
        }
        if useCloudKit {
            // Set CloudKit container options to enable syncing.
            storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.srgim.throttle.app")
        } else {
            // Remove CloudKit options to disable syncing.
            storeDescription.cloudKitContainerOptions = nil
        }
        
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        
        // Load persistent stores
        persistentContainer.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load Core Data stack: \(error)")
            }
            print("Successfully loaded persistent store: \(description)")
            print("Model URL: \(description.url?.absoluteString ?? "unknown")")
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
                print("Error saving context: \(error)")
            }
        }
    }
}
//
