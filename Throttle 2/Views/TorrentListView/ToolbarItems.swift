import SwiftUI
import CoreData

// MARK: - Server Menu Item
@ViewBuilder
func serverMenuToolbarItem(
    store: Store,
    presenting: Presenting,
    servers: FetchedResults<ServerEntity>
) -> some View {
    
        Button(action: {
            presenting.activeSheet = "adding"
        }, label: {
            Image(systemName: "plus")
            //Text("Add")
        }).buttonStyle(.borderless)
    if servers.count > 1 {
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
    }
}

// MARK: - iOS Settings Menu
#if os(iOS)
@ViewBuilder
func settingsMenuToolbarItem(presenting: Presenting) -> some View {
    Menu {
        Button(action: {
            presenting.activeSheet = "servers"
        }, label: {
            Image(systemName: "externaldrive").padding(.leading, 6)
            Text("Manage Servers")
        })
        .buttonStyle(.plain)
        
        Button(action: {
            presenting.activeSheet = "settings"
        }, label: {
            Image(systemName: "gearshape").padding(.leading, 6)
            Text("Settings")
        })
        .buttonStyle(.plain)
    } label: {
        Image(systemName: "gearshape")
    }
}
#endif

// MARK: - macOS Refresh Button
#if os(macOS)
@ViewBuilder
func refreshButtonToolbarItem(
    manager: TorrentManager,
    rotation: Binding<Double>
) -> some View {
    Button(action: {
        Task {
            try? await manager.fetchUpdates()
        }
    }) {
        if manager.isLoading {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .rotationEffect(.degrees(rotation.wrappedValue))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation.wrappedValue = 360
                    }
                }
        } else {
            Image(systemName: "arrow.trianglehead.2.clockwise")
        }
    }
    //.disabled(manager.isLoading)
}
#endif

// MARK: - Sort Menu
@ViewBuilder
func sortMenuToolbarItem(
    sortOption: Binding<String>
) -> some View {
    Menu {
        ForEach(SortOption.allCases, id: \.self) { option in
            Button(action: {
                sortOption.wrappedValue = option.rawValue
                SortOption.saveToDefaults(option)
            }) {
                HStack {
                    Text(option.rawValue)
                    if sortOption.wrappedValue == option.rawValue {
                        Image(systemName: "checkmark.circle")
                    } else {
                        Image(systemName: "circle")
                    }
                }
            }
        }
    } label: {
        Image(systemName: "arrow.up.and.down.text.horizontal")
    }
}

// MARK: - Toolbar Items Extension
extension View {
    @ViewBuilder
    func addTorrentListToolbarItems(
        store: Store,
        servers: FetchedResults<ServerEntity>,
        manager: TorrentManager,
        presenting: Presenting,
        rotation: Binding<Double>
    ) -> some View {
        self.toolbar {
            if UserDefaults.standard.bool(forKey: "sideBar") != true {
            ToolbarItemGroup(placement: .automatic) {
                FilterMenu(isSidebar: false)
            }
                    // Server selection menu (conditional)
                    ToolbarItemGroup(placement: .automatic) {
                        serverMenuToolbarItem(
                            store: store,
                            presenting: presenting,
                            servers: servers
                        )
                    }
                
            }
            
            // iOS-specific settings menu
            #if os(iOS)
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                settingsMenuToolbarItem(presenting: presenting)
            }
            #endif
            
            // macOS-specific refresh button
            #if targetEnvironment(macCatalyst) || os(macOS)
            ToolbarItemGroup(placement: .automatic) {
                refreshButtonToolbarItem(
                    manager: manager,
                    rotation: rotation
                )
            }
            #endif
        }
    }
}

