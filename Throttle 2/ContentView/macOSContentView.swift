//
//  macOSContentView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 19/3/2025.
//
#if os(macOS)
import SwiftUI
import KeychainAccess

struct MacOSContentView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default)
    var servers: FetchedResults<ServerEntity>
    @ObservedObject var presenting: Presenting
    @ObservedObject var manager: TorrentManager
    @ObservedObject var filter: TorrentFilters
    @ObservedObject var store: Store
    @State private var splitViewVisibility = NavigationSplitViewVisibility.automatic
//    @AppStorage("sideBar") var sideBar = false
    @AppStorage("detailView") private var detailView = false
    @AppStorage("firstRun") private var firstRun = true
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = true
    @State var isMounted = false

  @State private var isAnimating = false
    
    #if os(macOS)
    var mountManager = ServerMountManager()
#endif

    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true)
    
    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            ServerListContent(
                servers: servers,
                presenting: presenting,
                store: store,
                filter: filter
            )
            
        } content: {
            TorrentListView(manager: manager, store: store, presenting: presenting,  filter: filter ,isSidebarVisible: $isSidebarVisible)
            //.padding(.top, 10)
                .withToast()
                     .sheet( isPresented: $presenting.isCreating) {
                    CreateTorrent(store: store, presenting: presenting)
                        .frame(width: 400, height: 500)
                        .padding(20)
                }
                .navigationBarBackButtonHidden(true)
                .toolbar{
                    ToolbarItem (placement: .automatic) {
                        Button {
                            presenting.isCreating = true
                        } label: {
                            Image(systemName: "document.badge.plus")
                        }
                    }
                    ToolbarItem {
                        Button {
                            Task {
                                manager.reset()
                                manager.isLoading.toggle()
                            }
                        } label: {
                            if manager.isLoading{
                                Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                                .symbolEffect(.rotate)
                            } else{
                                Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                            }
                        }
                    }
                    if ((store.selection?.sftpBrowse) == true){
                        ToolbarItem (placement: .automatic) {
                            Button {
                                
                                let path = mountManager.getMountPath(for: store.selection!)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.absoluteString.replacingOccurrences(of: "file://", with: ""))
                                //NSWorkspace.shared.activateFileViewerSelecting([path])
                                
                            } label:{
                                
                                Image(systemName: "folder")
                            }
                        }
                    }
                    if !isSidebarVisible {
                                        if servers.count > 1 {
                                            ToolbarItem {
                                                Menu {
                                                    ForEach(servers) { server in
                                                        Button(action: {
                                                            store.selection = server
                                                        }, label: {
                                                            if store.selection == server {
                                                                Image(systemName: "checkmark.circle").padding(.leading, 6)
                                                            } else {
                                                                Image(systemName: "circle")
                                                            }
                                                            Text(server.isDefault ? (server.name ?? "") + " (Default)" : (server.name ?? ""))
                                                        })
                                                        .buttonStyle(.plain)
                                                    }
                                                } label: {
                                                    Image(systemName: "externaldrive.badge.wifi")
                                                }.disabled(manager.isLoading)
                                            }
                                        }
                    }
                }
            
        } detail: {
            if (store.selection == nil) {
                Rectangle().foregroundColor(.clear)
            } else {
                DetailsView(store: store, manager: manager)
            }
            
        }
        .onChange(of: splitViewVisibility) {
            print (splitViewVisibility)
            if splitViewVisibility == .all {
                isSidebarVisible = true
            } else {
                isSidebarVisible = false
            }
        }
    }
}
#endif
