//
//  ServerListContent.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//
import SwiftUI
import CoreData


struct ServerListContent: View {
    var servers: FetchedResults<ServerEntity>
    @ObservedObject var presenting: Presenting
    @ObservedObject var store: Store
    
    var body: some View {
        if servers.count > 0 {
            List(selection: $store.selection) {
                Section(servers.count > 1 ? "Servers" : "Server") {
                    ForEach(servers) { server in
                        ServerRow(server: server, presenting: presenting, store: store)
                    }
                }
            }
#if os(iOS)

                                Section("Settings"){
                                    Button("Manage Servers", systemImage: "rectangle.connected.to.line.below"){
                                        activeSheet = .servers
                                    }.buttonStyle(.plain)
                                    Button("App Settings", systemImage: "gearshape"){
                                        activeSheet = .settings
                                    }.buttonStyle(.plain)
                                }
                                //.padding(.leading, 0)}

            #endif
        } else {
            
#if os(macOS)
                            let word = "Click"
            #else
                            let word = "Tap"
                            #endif
                            ContentUnavailableView("Add a server to Begin",
                                systemImage: "server.rack",
                                description: Text("\(word) here to get started.")

                            ).onTapGesture {
                                //activeSheet = .servers
                            }
                        
        }
    }
}

struct ServerRow: View {
    let server: ServerEntity
    @ObservedObject var presenting: Presenting
    @ObservedObject var store: Store
    
    var body: some View {
        NavigationLink(value: server) {
            HStack {
                Image(systemName: "rectangle.connected.to.line.below")
                    .padding(.leading, 6)
                Text(server.isDefault ? "\(server.name ?? "") *" : server.name ?? "")
                    .padding(.leading, 0)
            }
        }
        .onAppear {
            if presenting.didStart && server.isDefault {
                store.selection = server
                presenting.didStart = false
            }
        }
        .buttonStyle(.plain)
    }
}
