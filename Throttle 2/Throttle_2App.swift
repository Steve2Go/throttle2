//
//  Throttle_2App.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 17/2/2025.
//

import SwiftUI

@main
struct Throttle_2App: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
