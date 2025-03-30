import SwiftUI
import CoreData
#if os(iOS)
import UIKit
#endif

struct TorrentListView: View {
    // Core data models and managers
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    @ObservedObject var presenting: Presenting
    @ObservedObject var filter: TorrentFilters
    
    // State  sorting
    
    
    @AppStorage("sortOption") var sortOption: String = "dateAdded"
    @AppStorage("filterOption") var filterOption: String = "all"
    // CoreData fetch request for servers
    @FetchRequest(
        entity: ServerEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default
    ) var servers: FetchedResults<ServerEntity>
    
    // UI state management
    @State private var showDeleteSheet = false
    @State private var showMoveSheet = false
    @State private var showRenameAlert = false
    @State private var selectedTorrent: Torrent?
    @State private var deleteSheet: TorrentDeleteSheet?
    @State private var mutateTorrent: MutateTorrent?
    @State private var selectedTorrentId: Int?
    @State private var showDetailsSheet = false
    @State var renameText = ""
    @State private var searchQuery: String = ""
    @State var selecting = false
    @State var selected: [Int] = []
    @State private var splitViewVisibility = NavigationSplitViewVisibility.automatic
    @Binding var isSidebarVisible: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDetailSheet = false
    
    
    #if os(iOS)
    var isiPad: Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }
    #endif
    // Sorted torrents
    var sortedTorrents: [Torrent] {
        var filtered = manager.torrents.filter { torrent in
            searchQuery.isEmpty || (torrent.name?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
        
        switch filterOption {
        case "starred":
            filtered = filtered.filter {
                // If labels is an array of strings, check if it contains "starred"
                let labels = $0.dynamicFields["labels"]?.value as? [String]
                return labels?.contains("starred") == true
                
            }
        case "downloading":
            filtered = filtered.filter { $0.status == 4 }
        case "seeding":
            // Make sure to use a closure with curly braces:
            filtered = filtered.filter { $0.status == 5 || $0.status == 6 }
        case "stopped":
            filtered = filtered.filter { $0.status == 0 }
        default:
            // Nothing to change in the default case
            break
        }
        
        switch sortOption {
        case "name":
            return filtered.sorted { ($0.name ?? "") < ($1.name ?? "") }
        case "activity":
            return filtered.sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
        default:
            return filtered.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        }
    }
    
    // Helper functions
    func deleteTorrent(_ torrent: Torrent) {
        deleteSheet = TorrentDeleteSheet(
            torrentManager: manager,
            torrents: [torrent],
            isPresented: $showDeleteSheet
        )
        deleteSheet?.present()
    }
    
    func setupMutation(_ torrent: Torrent) {
        selectedTorrent = torrent
        mutateTorrent = MutateTorrent(
            torrentManager: manager,
            torrent: torrent,
            showMoveSheet: $showMoveSheet,
            showRenameAlert: $showRenameAlert,
            server: store.selection
        )
    }
    
    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(sortedTorrents) { torrent in
                    TorrentRowView(
                        manager: manager,
                        store: store,
                        torrent: torrent,
                        onDelete: { deleteTorrent(torrent) },
                        onMove: {
                            setupMutation(torrent)
                            mutateTorrent?.move()
                        },
                        onRename: {
                            setupMutation(torrent)
                            mutateTorrent?.rename()
                        },
                        selecting : selecting,
                        selected : $selected
                    )
                    
                    
                }
            }
        }
        .sheet(isPresented: $showRenameAlert) {
            RenameSheetView(
                selectedTorrent: selectedTorrent,
                renameText: $renameText,
                showRenameAlert: $showRenameAlert,
                manager: manager
            )
        }
        .onChange(of: sortOption) {
            print("Sort option changed to: \(sortOption)")
        }
        .refreshable {
            Task {
                manager.reset()
                manager.isLoading.toggle()
            }
        }
        
        .searchable(text: $searchQuery, prompt: "Search")
              
        .toolbar {
            
            ToolbarItem(placement: .automatic) {
                if !selecting {
                    Button {
                        selecting.toggle()
                        selected = []
                    } label:{
                        Image(systemName: "checklist.unchecked")
                    }
                } else{
                    Menu {
                        Button("Stop Selecting", systemImage: "xmark") {
                            selecting.toggle()
                            selected = []
                        }
                        if selecting {
                            Button("Select All", systemImage: "checkmark.circle.fill") {
                                selected = sortedTorrents.map { $0.id }
                            }
                            Button("Select None", systemImage: "checkmark.circle.badge.xmark") {
                                selected = []
                            }
                            if selected != [] {
                                Button("Start Selected", systemImage: "play") {
                                    Task{
                                        try await manager.startTorrents(ids: selected)
                                    }
                                    selecting.toggle()
                                }
                                Button("Stop Selected", systemImage: "stop") {
                                    Task{
                                        try await manager.stopTorrents(ids: selected)
                                    }
                                    selecting.toggle()
                                }
                                Button("Verify Selected", systemImage: "externaldrive.badge.questionmark") {
                                    Task{
                                        try await manager.verifyTorrents(ids: selected)
                                    }
                                    selecting.toggle()
                                }
                                Button("Announce Selected", systemImage: "megaphone") {
                                    Task{
                                        try await manager.reannounceTorrents(ids: selected)
                                    }
                                    selecting.toggle()
                                }
                            }
                        }
                    } label: {
                        
                        #if os(macOS)
                        Image(systemName: "checklist")
                        #else
                        ZStack{
                            Image(systemName: "checklist")
                                .colorInvert()
                        }
                        #endif
                    }
                }
            }

            if !isSidebarVisible {

                ToolbarItem (placement: .automatic){
                    FilterMenu(isSidebar: false)
                }
            }
            
            
        }
        .onAppear {
            print("🚀 View appeared, starting periodic updates")
            manager.startPeriodicUpdates()
        }
        .onDisappear {
            print("👋 View disappeared, stopping updates")
            manager.stopPeriodicUpdates()
        }
        .sheet(isPresented: $showDeleteSheet) {
            if let deleteSheet = deleteSheet {
                
                deleteSheet.sheet
#if os(iOS)
.presentationDetents([.medium])
#endif
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            if let mutateTorrent = mutateTorrent {
                mutateTorrent.moveSheet
                    #if os(iOS)
                    .presentationDetents([.medium])
                    #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $store.FileBrowse, onDismiss: {}, content: {
            Group {
                if let url = store.fileURL, let torrentName = store.fileBrowserName {

                    #if os(iOS)
                    SFTPFileBrowserView(
                        currentPath: url + "/" + torrentName,
                        basePath: url + "/" + torrentName, //(store.selection?.pathServer) ?? "",
                        server: store.selection,
                        store: store
                    )
                    #endif
                    
                } else {
                    // Fallback if path not available
                    VStack {
                        ProgressView()
                        Text("Loading file browser...")
                    }
                }
            }
        })
        .fullScreenCover(isPresented: $store.FileBrowseCover, onDismiss: {}, content: {
            Group {
                if let url = store.fileURL, let torrentName = store.fileBrowserName {

                    #if os(iOS)
                    SFTPFileBrowserView(
                        currentPath: url + "/" + torrentName,
                        basePath: url + "/" + torrentName, //(store.selection?.pathServer) ?? "",
                        server: store.selection,
                        store: store
                    )
                    #endif
                    
                } else {
                    // Fallback if path not available
                    VStack {
                        ProgressView()
                        Text("Loading file browser...")
                    }
                }
            }
        })
        #endif
    }
}
//#if os(iOS)
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .resizable()
                .frame(width: 20, height: 20).padding(10)
                .foregroundColor(.accentColor)
//            RoundedRectangle(cornerRadius: 5.0)
//                .stroke(lineWidth: 2)
//                .frame(width: 25, height: 25)
//                .cornerRadius(5.0)
//                .overlay {
//                    Image(systemName: configuration.isOn ? "checkmark" : "")
//                }
                .onTapGesture {
                    withAnimation(.spring()) {
                        configuration.isOn.toggle()
                    }
                }

            configuration.label

        }
    }
}
//#endif
