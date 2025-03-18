//
//  ContentView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 17/2/2025.
//

import SwiftUI
import CoreData
import KeychainAccess

enum ActiveSheet: Identifiable {
    case adding
    case servers
    case settings
    
    var id: Self { self }  // Use the enum case itself as the identifier
}


struct ContentView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Servers.name, ascending: true)],
            animation: .default)
        var servers: FetchedResults<Servers>
    @ObservedObject var presenting: Presenting
    @ObservedObject var manager = TorrentManager()
    @ObservedObject var filter: TorrentFilters
    @ObservedObject var store: Store
    @Binding var activeSheet: ActiveSheet?
    @State private var splitViewVisibility = NavigationSplitViewVisibility.all
    
    // @State private var selection: Servers?
    
    
    var body: some View {
        Text("test")
//
//        NavigationSplitView(columnVisibility: $splitViewVisibility) {
//            
//            if servers.count > 0 {
//                List (selection: $store.selection){
//                    //servers shows for both OS
//                    Section (servers.count > 1 ? "Servers" :"Server") {
//                        ForEach(servers) { server in
//                            NavigationLink(value: server) {
//                                //
//                                Image(systemName: "rectangle.connected.to.line.below").padding(.leading,6 )
//                                Text(server.isDefault ? server.name + " *": server.name)
//                                
//                                    .padding(.leading, 0)
//                                
//                            }
//                            .onAppear{
//                                if  presenting.didStart && server.isDefault {
//                                    store.selection = server
//                                    presenting.didStart = false
//                                }
//                            }
//                            .buttonStyle(.plain)
//                        }
//                        
//                    }
//                    
//                    
//                    
//                    
//#if os(iOS)
//                    
//                    Section("Settings"){
//                        Button("Manage Servers", systemImage: "rectangle.connected.to.line.below"){
//                            activeSheet = .servers
//                        }.buttonStyle(.plain)
//                        Button("App Settings", systemImage: "gearshape"){
//                            activeSheet = .settings
//                        }.buttonStyle(.plain)
//                    }
//                    //.padding(.leading, 0)}
//                    
//#endif
//                    
//                    
//                    // on macos this holds the filters if sidebar is showing
//#if os(macOS)
//                    //Divider()
//                    FilterMenu(filters: filter)
//                    
//#endif
//                }
//                .navigationTitle("Throttle")
//            } else {
//#if os(macOS)
//                let word = "Click"
//#else
//                let word = "Tap"
//                #endif
//                ContentUnavailableView("Add a server to Begin",
//                    systemImage: "server.rack",
//                    description: Text("\(word) here to get started.")
//
//                ).onTapGesture {
//                    activeSheet = .servers
//                }
//            }
//
//            
//            
//            
//            //Text("Select an item")
//        }
//        
//        content: {
//            //ListView(presenting: presenting, server: selection)
//            if store.connectTransmission != "" {
//                //TorrentListView(baseURL: URL(string: store.connectTransmission)!)
//                
//                if let server = store.selection{
//                    // Each time server changes, SwiftUI creates a new TorrentListView
//                    // with a fresh TorrentManager
//                    TorrentListView(manager: manager, baseURL: URL( string: store.connectTransmission)!, activeSheet: $activeSheet, store: store)
//                        
//                    //manager.updateBaseURL(URL( string: store.connectTransmission)!)
//                    
//                        .toolbar {
//                            ToolbarItem(placement: .automatic, content: {
//                                Button(action: {
//                                    
//                                    store.selection = nil
//                                }) {
//                                    Label("Filters", systemImage: "line.3.horizontal.decrease")
//                                }
//                            })
//                            ToolbarItem(placement: .automatic) {
//                                Button(action: {
//                                    activeSheet = .adding
//                                }) {
//                                    Label("Add", systemImage: "plus")
//                                }
//                            }
//                            
//                        }.navigationBarBackButtonHidden(true)
//                        .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 600)
//                }
//            } else {
//                ContentUnavailableView("Select a Server",
//                                       systemImage: "server.rack",
//                                       description: Text("Choose a server from the list or add a new one")
//                )
//            }
//        } detail: {
//            
//            DetailsView( store: store , manager: manager)
//            
//        }
//        .sheet(item: $activeSheet, onDismiss: {
//            store.selectedFile = nil
//            store.magnetLink = ""
//        }) { sheet in
//            switch sheet {
//            case .adding:
//                if let selectedServer = store.selection {
//                    AddTorrentView(store: store,
//                                   manager: manager,
//                                   currentServer: selectedServer,
//                                   presenting: presenting,
//                                   activeSheet: $activeSheet)
//                    .presentationDetents([.medium])
//#if os(macOS)
//                    .frame(width: 600, height: 210)
//#endif
//                }
//            case .servers:
//                ServersListView(presenting: presenting,
//                                activeSheet: $activeSheet, store: store)
//                .presentationDetents([.large])
//#if os(macOS)
//                .frame(width: 500, height: 500)
//#endif
//            case .settings:
//                SettingsView(presenting: presenting,
//                             activeSheet: $activeSheet)
//                
//                
//#if os(macOS)
//                .frame(width: 600, height: 550)
//                #else
//                .presentationDetents([.large])
//#endif
//            }
//               
//        } .onOpenURL { (url) in
//            if url.isFileURL{
//                store.selectedFile = url
//                store.selectedFile!.startAccessingSecurityScopedResource()
//            } else{
//                store.magnetLink = url.absoluteString
//            }
//            Task{
//                try await Task.sleep(for: .milliseconds(500))
//                activeSheet = .adding
//            }
//            
          }
        
//#if os(macOS)
//.onChange(of: splitViewVisibility, perform: { newValue in
//    print("Raw splitViewVisibility change: \(newValue)")
//    
//    if newValue == .all || newValue == .all {
//        store.sideBar = true
//        print("Sidebar is open")
//    } else {
//        store.sideBar = false
//        print("Sidebar is closed")
//    }
//})
//#endif
//      
//    }
//    func dismissSheet() {
//        activeSheet = nil
//    }
//    
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()


