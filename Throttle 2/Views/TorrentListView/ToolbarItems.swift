import SwiftUI

struct ToolbarItems: ToolbarContent {
    @ObservedObject var store: Store
    let servers: FetchedResults<ServerEntity>
    @Binding var sortOption: String
    @ObservedObject var manager: TorrentManager
    @Binding var rotation: Double
    
    var body: some ToolbarContent {
        if store.sideBar == false {
            ToolbarItemGroup(placement: .automatic) {
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
                    Image(systemName: "rectangle.connected.to.line.below")
                }
            }
        }
        
        #if os(iOS)
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button(action: {
                    store.activeSheet = .servers
                }, label: {
                    Image(systemName: "rectangle.connected.to.line.below").padding(.leading, 6)
                    Text("Manage Servers")
                })
                .buttonStyle(.plain)
                
                Button(action: {
                    store.activeSheet = .settings
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
        
        #if os(macOS)
        ToolbarItemGroup(placement: .automatic) {
            Button(action: {
                Task {
                    try? await manager.fetchUpdates(fields: [
                        "id", "name", "percentDone", "percentComplete", "status",
                        "downloadedEver", "uploadedEver", "totalSize",
                        "error", "errorString", "files", "labels"
                    ], isFullRefresh: true)
                }
            }) {
                if manager.isLoading {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .rotationEffect(.degrees(rotation))
                        .onAppear {
                            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                }
            }
            .disabled(manager.isLoading)
        }
        #endif
        
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(action: {
                        sortOption = option.rawValue
                        SortOption.saveToDefaults(option)
                    }) {
                        HStack {
                            Text(option.rawValue)
                            if sortOption == option.rawValue {
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
    }
}