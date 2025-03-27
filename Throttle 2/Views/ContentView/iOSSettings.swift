//
//  iOSSettings.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//
import SwiftUI

struct iOSSidebarSettings: View {
    //@ObservedObject var filters: TorrentFilters
    @ObservedObject var store: Store
    @ObservedObject var presenting: Presenting
    
    var body: some View {
    
            Section("Settings"){
                Button("Manage Servers", systemImage: "externaldrive"){
                    presenting.activeSheet = "servers"
                }.buttonStyle(.plain)
                Button("App Settings", systemImage: "gearshape"){
                    presenting.activeSheet = "settings"
                }.buttonStyle(.plain)
            }
     
    }
}
