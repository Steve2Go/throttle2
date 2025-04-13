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
    @ObservedObject var filter: TorrentFilters
    
    var body: some View {
        if servers.count > 0 {
            List(selection: $store.selection) {
                Section(servers.count > 1 ? "Servers" : "Server") {
                    ForEach(servers) { server in
                        ServerRow(server: server, presenting: presenting, store: store)
                    }
                }

                FilterMenu(isSidebar: true)

#if os(iOS)
                iOSSidebarSettings(store:store, presenting: presenting)
#endif
            }
            
        }
    }
}

struct ServerRow: View {
    let server: ServerEntity
    @ObservedObject var presenting: Presenting
    @ObservedObject var store: Store
    
    var body: some View {
        
        Button() {
            store.selection = server
        } label:{
                    
                        
                        if server == store.selection {
                            Image(systemName: "externaldrive.badge.checkmark").foregroundColor(.blue)
                                .padding(.leading, 6)
                                .foregroundStyle(.primary)
                        } else {
                            Image(systemName: "externaldrive").foregroundColor(.blue)
                                .padding(.leading, 6)
                                .foregroundStyle(.primary)
                        }
                        Text(server.isDefault ? "\(server.name ?? "") *" : server.name ?? "")
                            .padding(.leading, 0)
                            .foregroundColor(.primary)
                    
        }.buttonStyle(.borderless)
//        NavigationLink(value: server) {
//            HStack {
//                Image(systemName: "externaldrive")
//                    .padding(.leading, 6)
//                Text(server.isDefault ? "\(server.name ?? "") *" : server.name ?? "")
//                    .padding(.leading, 0)
//            }
//        }
//        .onAppear {
//            if presenting.didStart && server.isDefault {
//                store.selection = server
//                presenting.didStart = false
//            }
//        }
//        .buttonStyle(.plain)
    }
}
