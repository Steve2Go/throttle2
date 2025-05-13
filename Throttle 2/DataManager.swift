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
    @AppStorage("useCloudKit") var useCloudKit: Bool = true

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
        
        // Set persistent store location to App Group container for sharing between main app and helper
        let appGroupID = "group.com.srgim.Throttle-2"
        let fileManager = FileManager.default
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let appGroupStoreURL = appGroupURL.appendingPathComponent("CoreData.sqlite")
            let oldStoreURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CoreData.sqlite")

            // Get modification dates
            let oldStoreDate = (try? fileManager.attributesOfItem(atPath: oldStoreURL.path)[.modificationDate] as? Date) ?? Date.distantPast
            let appGroupStoreDate = (try? fileManager.attributesOfItem(atPath: appGroupStoreURL.path)[.modificationDate] as? Date) ?? Date.distantPast

            // Only migrate if old store is newer
            if oldStoreDate > appGroupStoreDate {
                // Remove existing App Group store and -shm/-wal files for a clean migration
                let appGroupShm = appGroupStoreURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
                let appGroupWal = appGroupStoreURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
                if fileManager.fileExists(atPath: appGroupStoreURL.path) {
                    try? fileManager.removeItem(at: appGroupStoreURL)
                }
                if fileManager.fileExists(atPath: appGroupShm.path) {
                    try? fileManager.removeItem(at: appGroupShm)
                }
                if fileManager.fileExists(atPath: appGroupWal.path) {
                    try? fileManager.removeItem(at: appGroupWal)
                }

                // Copy old store and -shm/-wal files as before
                do {
                    try fileManager.copyItem(at: oldStoreURL, to: appGroupStoreURL)
                    let shm = oldStoreURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
                    let wal = oldStoreURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
                    if fileManager.fileExists(atPath: shm.path) {
                        try fileManager.copyItem(at: shm, to: appGroupShm)
                    }
                    if fileManager.fileExists(atPath: wal.path) {
                        try fileManager.copyItem(at: wal, to: appGroupWal)
                    }
                    print("✅ Migrated Core Data store to App Group container (old store was newer).")
                } catch {
                    print("⚠️ Failed to migrate Core Data store: \(error)")
                }
            } else {
                print("ℹ️ Skipped migration: App Group store is newer or same age.")
            }
        }
        if let storeURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.appendingPathComponent("CoreData.sqlite") {
            storeDescription.url = storeURL
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
