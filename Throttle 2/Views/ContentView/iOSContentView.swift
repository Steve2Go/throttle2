#if os(iOS)
import SwiftUI
import KeychainAccess
import UIKit

struct iOSContentView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default)
    var servers: FetchedResults<ServerEntity>
    @ObservedObject var presenting: Presenting
    @ObservedObject var manager: TorrentManager
    @ObservedObject var filter: TorrentFilters
    @ObservedObject var store: Store
    @AppStorage("detailView") private var detailView = false
    @AppStorage("firstRun") private var firstRun = true
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = false
    @State var isMounted = false
    @State private var splitViewVisibility = NavigationSplitViewVisibility.automatic
    @State var isCreating = false
    
    let isiPad = UIDevice.current.userInterfaceIdiom == .pad
    
    // Create a shared view builder for the TorrentListView with toolbar
    @ViewBuilder
    func torrentListWithToolbar() -> some View {
        TorrentListView(manager: manager, store: store, presenting: presenting, filter: filter, isSidebarVisible: $isSidebarVisible)
            .withToast()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        presenting.activeSheet = "adding"
                    }, label: {
                        Image(systemName: "plus")
                    })
                }
                
                if ((store.selection?.sftpBrowse) != nil) {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            store.fileURL = store.selection?.pathServer
                            store.fileBrowserName = ""
                            if isiPad {
                                store.FileBrowse = true
                            } else {
                                store.FileBrowseCover = true
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                    }
                }
                
                // Only show server selector if we have multiple servers and either:
                // 1. We're on iPhone, or
                // 2. We're on iPad but the sidebar isn't visible
                if servers.count > 1 && (!isiPad || (isiPad && !isSidebarVisible)) {
                    ToolbarItem(placement: .navigationBarTrailing) {
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
                        }
                        .disabled(manager.isLoading)
                    }
                }
                if (!isiPad || (isiPad && !isSidebarVisible)) {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                presenting.isCreating = true
                            } label: {
                                Label("Create Torrent", systemImage: "document.badge.plus")
                            }
                            Divider()
                            Button(action: {
                                presenting.activeSheet = "servers"
                            }, label: {
                                Label("Manage Servers", systemImage: "externaldrive")
                            })
                            Button(action: {
                                presenting.activeSheet = "settings"
                            }, label: {
                                Label("Settings", systemImage: "gearshape")
                            })
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            //.navigationTitle(store.selection?.name ?? "Torrents").font(.caption)
            .navigationBarTitleDisplayMode(.inline)
    }
    
    var body: some View {
        Group {
            if isiPad {
                
                NavigationView {
                    ServerListContent(
                        servers: servers,
                        presenting: presenting,
                        store: store,
                        filter: filter
                    ).listStyle(SidebarListStyle())
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        isSidebarVisible = true
                                    }
                                    .onDisappear {
                                        isSidebarVisible = false
                                    }
                                
                            }
                        )
                    VStack{
                        torrentListWithToolbar().padding(.bottom,0)
                    }
                }
                .navigationViewStyle(DoubleColumnNavigationViewStyle())
                
                
            } else {
                // iPhone uses NavigationStack if available, otherwise NavigationView
                if #available(iOS 16, *) {
                    NavigationStack {
                        torrentListWithToolbar().padding(.bottom,0)
                    }
                } else {
                    NavigationView {
                        torrentListWithToolbar().padding(.bottom,0)
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                }
            }
        }
        .onAppear {
            if !isiPad {
                isSidebarVisible = false
            }
            
            // Make sure we have a server selected
//            if store.selection == nil {
//                store.selection = servers.first(where: { $0.isDefault }) ?? servers.first
//            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet( isPresented: $presenting.isCreating) {
            //NavigationStack{
            CreateTorrent(store: store, presenting: presenting)
               
        //}
    }
        
        // Sheet handling - place outside the NavigationView/Stack for proper presentation
        .sheet(item: createActiveSheetBinding(presenting)) { sheetType in
            switch sheetType {
            case .settings:
                SettingsView(presenting: presenting, manager: manager)
            case .servers:
                ServersListView(presenting: presenting, store: store)
            case .adding:
                AddTorrentView(store: store, manager: manager, presenting: presenting)
                    .presentationDetents([.medium])
            }
        }
    }
    
    // Helper method to create binding for sheets
    private func createActiveSheetBinding(_ presenting: Presenting) -> Binding<SheetType?> {
        return Binding<SheetType?>(
            get: {
                if let sheetString = presenting.activeSheet {
                    return SheetType(rawValue: sheetString)
                }
                return nil
            },
            set: { presenting.activeSheet = $0?.rawValue }
        )
    }
}
#endif
