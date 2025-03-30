////
////  DataManager.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 1/3/2025.
////
import SwiftUI
import CoreData
//
////final class DataManager {
////    static let shared = DataManager()
////    static var initCount = 0
////    
////    let persistentContainer: NSPersistentContainer
////    
////    private init() {
////        DataManager.initCount += 1
////        print("⚠️ DataManager initialized \(DataManager.initCount) times")
////        
////        // Initialize with NSPersistentContainer
////        persistentContainer = NSPersistentContainer(name: "CoreData")
////        
////        persistentContainer.loadPersistentStores { description, error in
////            if let error = error {
////                fatalError("Failed to load Core Data stack: \(error)")
////            }
////            print("Successfully loaded persistent store: \(description)")
////            print("Model URL: \(description.url?.absoluteString ?? "unknown")")
////        }
////        
////        // Configure the view context
////        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
////        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
////    }
////    
////    var viewContext: NSManagedObjectContext {
////        return persistentContainer.viewContext
////    }
////    
////    func saveContext() {
////        let context = viewContext
////        if context.hasChanges {
////            do {
////                try context.save()
////            } catch {
////                print("Error saving context: \(error)")
////            }
////        }
////    }
////}
////
//
//
////final class DataManager {
////    static let shared = DataManager()
////    static var initCount = 0
////    @AppStorage("useCloudKit") var useCloudKit: Bool = true
////    
////
////    
////    let persistentContainer: NSPersistentCloudKitContainer
////    
////    private init() {
////        DataManager.initCount += 1
////        print("⚠️ DataManager initialized \(DataManager.initCount) times")
////        
////        // Initialize with NSPersistentCloudKitContainer
////        persistentContainer = NSPersistentCloudKitContainer(name: "CoreData")
////        
////        // Configure the persistent store description for CloudKit.
////        guard let storeDescription = persistentContainer.persistentStoreDescriptions.first else {
////            fatalError("No persistent store description found")
////        }
////        // Set the CloudKit container identifier (update the identifier to match your iCloud container)
////        storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.srgim.throttle.app")
////        
////        // Load persistent stores
////        persistentContainer.loadPersistentStores { description, error in
////            if let error = error {
////                fatalError("Failed to load Core Data stack: \(error)")
////            }
////            print("Successfully loaded persistent store: \(description)")
////            print("Model URL: \(description.url?.absoluteString ?? "unknown")")
////        }
////        
////        // Configure the view context for automatic merging and merge policies.
////        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
////        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
////    }
////    
////    var viewContext: NSManagedObjectContext {
////        return persistentContainer.viewContext
////    }
////    
////    func saveContext() {
////        let context = viewContext
////        if context.hasChanges {
////            do {
////                try context.save()
////            } catch {
////                print("Error saving context: \(error)")
////            }
////        }
////    }
////}
//
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
//

//
//import CoreData
//import SwiftUI
//
//final class DataManager {
//    static let shared = DataManager()
//    static var initCount = 0
//    @AppStorage("useCloudKit") var useCloudKit: Bool = true
//
//    let persistentContainer: NSPersistentCloudKitContainer
//
//    private init() {
//        DataManager.initCount += 1
//        //print("⚠️ DataManager initialized \(DataManager.initCount) times")
//        
//        // Initialize with NSPersistentCloudKitContainer using your model name.
//        persistentContainer = NSPersistentCloudKitContainer(name: "CoreData")
//        
//        // Get the shared store URL from the App Group "group.com.srgim.Throttle-2".
//        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.srgim.Throttle-2") {
//            let storeURL = containerURL.appendingPathComponent("CoreData.sqlite")
//            if let storeDescription = persistentContainer.persistentStoreDescriptions.first {
//                storeDescription.url = storeURL
//                if useCloudKit {
//                    storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.srgim.throttle.app")
//                } else {
//                    storeDescription.cloudKitContainerOptions = nil
//                }
//            }
//        } else {
//            fatalError("Unable to find App Group container URL")
//        }
//        
//        persistentContainer.loadPersistentStores { description, error in
//            if let error = error {
//                fatalError("Failed to load Core Data stack: \(error)")
//            }
//            //print("Main app persistent store loaded at: \(description.url?.absoluteString ?? "unknown")")
//        }
//        
//        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
//        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
//    }
//    
//    var viewContext: NSManagedObjectContext {
//        return persistentContainer.viewContext
//    }
//    
//    func saveContext() {
//        let context = viewContext
//        if context.hasChanges {
//            do {
//                try context.save()
//            } catch {
//                //print("Error saving context: \(error)")
//            }
//        }
//    }
//}
