import SwiftUI
import CoreData
import SimpleToast
#if os(iOS)
import UIKit
#endif

struct TorrentListView: View {
    // Core data models and managers
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    @ObservedObject var presenting: Presenting
    @ObservedObject var filter: TorrentFilters
    
    // State for sorting
    @AppStorage("sortOption") var sortOption: String = "dateAdded"
    @AppStorage("filterOption") var filterOption: String = "all"
    @AppStorage("filterdCount") var filterdCount: Int = 0
    // CoreData fetch request for servers
    @FetchRequest(
        entity: ServerEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default
    ) var servers: FetchedResults<ServerEntity>
    
    // UI state management
    @State private var showDeleteAlert = false
    @State private var showMultipleDeleteAlert = false
    @State private var showRenameAlert = false
    @State private var showMoveAlert = false
    @State private var selectedTorrent: Torrent?
    @State private var selectedTorrentId: Int?
    @State private var showDetailsSheet = false
    @State private var showServerSettings = false
    @State private var renameText = ""
    @State private var moveLocation = ""
    @State private var searchQuery: String = ""
    @State private var selecting = false
    @State private var selected: [Int] = []
    @State private var splitViewVisibility = NavigationSplitViewVisibility.automatic
    @Binding var isSidebarVisible: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDetailSheet = false
    @State private var showFileBrowser = false


    
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
            filtered = filtered.filter { $0.status == 5 || $0.status == 6 }
        case "stopped":
            filtered = filtered.filter { $0.status == 0 }
        default:
            // Nothing to change in the default case
            break
        }
        filterdCount = filtered.count
        
        switch sortOption {
        case "name":
            return filtered.sorted { ($0.name ?? "") < ($1.name ?? "") }
        case "activity":
            return filtered.sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
        default:
            return filtered.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        }
    }
    
    var body: some View {
    VStack{
            ScrollView {
                LazyVStack {
#if os(iOS)
                    if manager.isLoading {
                        ProgressView()
                    }
#endif
                    
                    ForEach(sortedTorrents) { torrent in
                        TorrentRowView(
                            manager: manager,
                            store: store,
                            torrent: torrent,
                            onDelete: { deleteTorrent(torrent) },
                            onMove: { moveTorrent(torrent) },
                            onRename: { renameTorrent(torrent) },
                            selecting: selecting,
                            selected: $selected,
                        )
                    }
                }.padding(.bottom, 0)
            }.padding(.bottom, 0)
            ServerStatusBar(
                manager: manager,
                store: store,
                showServerSettings: $showServerSettings,
            ).padding(.top,-10)
//                .onTapGesture {
//                    #if os(iOS)
//                    if !isiPad {
//                        showServerSettings.toggle()
//                    }
//                    #endif
//                }
    }
#if os(macOS)
    // Enforce minimum practical width for torrent list panel
    .frame(minWidth: 420)
#endif
        
       
        .onChange(of: sortOption) {
            ToastManager.shared.show(message: "Sorted by: \(sortOption)", icon: "arrow.down.app", color: Color.blue)
            print("Sort option changed to: \(sortOption)")
        }
        .onChange(of: filterOption){
            ToastManager.shared.show(message: "Showing: \(filterOption)", icon: "line.3.horizontal.decrease", color: Color.blue)
        }
        .refreshable {
            Task {
                // do a full reset on refresh
                manager.isLoading.toggle()
                let saveserver = store.selection
                store.selection = nil
                try? await Task.sleep(nanoseconds: 1_00_000_000)
                store.selection = saveserver
                manager.reset()
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
                                    ToastManager.shared.show(message: "Start Request Sent", icon: "play", color: .green)
                                    selecting.toggle()
                                }
                                Button("Stop Selected", systemImage: "stop") {
                                    ToastManager.shared.show(message: "Stop Request Sent", icon: "stop", color: .red)
                                    selecting.toggle()
                                }
                                Button("Verify Selected", systemImage: "externaldrive.badge.questionmark") {
                                    ToastManager.shared.show(message: "Verify Request Sent", icon: "externaldrive.badge.questionmark", color: .orange)
                                    selecting.toggle()
                                }
                                Button("Announce Selected", systemImage: "megaphone") {
                                    ToastManager.shared.show(message: "Announce Request Sent", icon: "megaphone", color: .green)
                                    selecting.toggle()
                                }
                                Button("Delete Selected", systemImage: "trash") {
                                    deleteSelectedTorrents()
                                }
                            }
                        }
                    } label: {
                        #if os(macOS)
                        Image(systemName: "checklist")
                        #else
                        ZStack{
                            Image(systemName: "checklist")
                                .foregroundColor(.orange)
                        }
                        #endif
                    }
                }
            }

            if !isSidebarVisible {
                ToolbarItem(placement: .automatic){
                    FilterMenu(isSidebar: false)
                }
            }
        }
        
        .onAppear {
//            if TunnelManagerHolder.shared.getTunnel(withIdentifier: "http-streamer") != nil{
//                activateThumbnails()
//            }
            print("🚀 View appeared, starting periodic updates")
            manager.startPeriodicUpdates()
        }
        .onDisappear {
            print("👋 View disappeared, stopping updates")
            manager.stopPeriodicUpdates()
        }
       
        
        // Delete Alert
        .alert("Delete Torrent", isPresented: $showDeleteAlert) {
            Button("Delete Files", role: .destructive) {
                Task {
                    await performDelete(deleteFiles: true)
                }
            }
            
            Button("Remove Torrent Only", role: .destructive) {
                Task {
                    await performDelete(deleteFiles: false)
                }
            }
            
            Button("Cancel", role: .cancel) {}
            
        } message: {
            if let name = selectedTorrent?.name {
                Text("Are you sure you want to remove \(name)?")
            } else {
                Text("Are you sure you want to remove this torrent?")
            }
        }
        
        // Multiple Delete Alert
        .alert("Delete Torrents", isPresented: $showMultipleDeleteAlert) {
            Button("Delete Files", role: .destructive) {
                Task {
                    await performMultipleDelete(deleteFiles: true)
                }
            }
            
            Button("Remove Torrents Only", role: .destructive) {
                Task {
                    await performMultipleDelete(deleteFiles: false)
                }
            }
            
            Button("Cancel", role: .cancel) {}
            
        } message: {
            Text("Are you sure you want to remove \(selected.count) torrents?")
        }
        
        // Rename Sheet
        .sheet(isPresented: $showRenameAlert) {
            renameSheet
        }
        
        // Move Sheet
        .sheet(isPresented: $showMoveAlert) {
            moveSheet
        }
        
        // File Browser Sheet (used inside the move sheet)
        .sheet(isPresented: $showFileBrowser) {
            fileBrowserSheet
        }
        
        // Server Settings
        .sheet(isPresented: $showServerSettings) {
            TransmissionSettingsView (manager: manager, store: store )
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
                    ).withToast()
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
                    ).withToast()
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
    
    // MARK: Delete Torrent
    
    func deleteTorrent(_ torrent: Torrent) {
        selectedTorrent = torrent
        showDeleteAlert = true
    }
    
    func performDelete(deleteFiles: Bool) async {
        guard let torrent = selectedTorrent else { return }
        
        do {
            let success = try await manager.deleteTorrents(
                ids: [torrent.id],
                deleteLocalData: deleteFiles
            )
            
            if success {
                await MainActor.run {
                    showDeleteAlert = false
                    selectedTorrent = nil
                }
            }
        } catch {
            print("Error deleting torrent:", error)
        }
    }
    
    // MARK: Rename Torrent
    
    func renameTorrent(_ torrent: Torrent) {
        selectedTorrent = torrent
        renameText = torrent.name ?? ""
        showRenameAlert = true
    }
    
    func performRename() async {
        guard let torrent = selectedTorrent, !renameText.isEmpty else { return }
        
        do {
            let _ = try await manager.renamePath(
                ids: [torrent.id],
                path: torrent.name ?? "",
                newName: renameText
            )
            
            await MainActor.run {
                showRenameAlert = false
                selectedTorrent = nil
            }
        } catch {
            print("Error renaming torrent:", error)
        }
    }
    
    // MARK: Move Torrent
    
    func moveTorrent(_ torrent: Torrent) {
        selectedTorrent = torrent
        
        // Get current download directory
        Task {
            if let downloadDir = try? await manager.getDownloadDirectory() {
                await MainActor.run {
                    moveLocation = downloadDir
                }
            }
        }
        
        showMoveAlert = true
    }
    
    func performMove() async {
        guard let torrent = selectedTorrent, !moveLocation.isEmpty else { return }
        
        do {
            let success = try await manager.moveTorrents(
                ids: [torrent.id],
                to: moveLocation,
                move: true
            )
            
            if success {
                await MainActor.run {
                    showMoveAlert = false
                    selectedTorrent = nil
                }
            }
        } catch {
            print("Error moving torrent:", error)
        }
    }
    
    // MARK: Multiple Torrents Operations
    
    func deleteSelectedTorrents() {
        if selected.isEmpty { return }
        showMultipleDeleteAlert = true
    }
    
    func performMultipleDelete(deleteFiles: Bool) async {
        do {
            let success = try await manager.deleteTorrents(
                ids: selected,
                deleteLocalData: deleteFiles
            )
            
            if success {
                await MainActor.run {
                    showMultipleDeleteAlert = false
                    selected = []
                    selecting = false
                }
            }
        } catch {
            print("Error deleting torrents:", error)
        }
    }
    
    // MARK: - Alert and Sheet Views
    
    var renameSheet: some View {
        #if os(iOS)
        NavigationView {
            Form {
                Section("Current Name") {
                    Text(selectedTorrent?.name ?? "")
                        .foregroundStyle(.secondary)
                }
                
                Section("New Name") {
                    HStack {
                        TextField("Enter new name", text: $renameText)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                        
                        Button("Rename") {
                            Task {
                                await performRename()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameText.isEmpty)
                    }
                }
            }
            .navigationTitle("Rename Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showRenameAlert = false
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        #else
        VStack(spacing: 12) {
            Text("Current name:")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(selectedTorrent?.name ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            
            Divider()
            
            HStack {
                TextField("New name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                
                Button("Rename") {
                    Task {
                        await performRename()
                    }
                }
                .keyboardShortcut(.return)
                .disabled(renameText.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        #endif
    }
    
    var moveSheet: some View {
        #if os(iOS)
        NavigationView {
            Form {
                Section("New Location") {
                    HStack {
                        TextField("Enter new location", text: $moveLocation)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        if store.selection?.sftpBrowse == true {
                            Button {
                                showFileBrowser = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Move Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showMoveAlert = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        Task {
                            await performMove()
                        }
                    }.disabled(moveLocation.isEmpty)
                }
            }
            .presentationDetents([.medium])
        }
        #else
        VStack(spacing: 20) {
            Text("Move Torrent").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("New Location:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("", text: $moveLocation)
                        .textFieldStyle(.roundedBorder)
                    
                    if store.selection?.fsBrowse == true {
                        Button("", systemImage: "folder") {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.allowsOtherFileTypes = false
                            panel.canChooseDirectories = true
                            
                            if panel.runModal() == .OK,
                               let fpath = panel.url,
                               let filesystemPath = store.selection?.pathFilesystem,
                               let serverPath = store.selection?.pathServer {
                                
                                let movepath = fpath.absoluteString.replacingOccurrences(
                                    of: "file://" + filesystemPath,
                                    with: serverPath
                                )
                                
                                moveLocation = movepath
                            }
                        }.labelsHidden()
                    } else if store.selection?.sftpBrowse == true {
                        Button { showFileBrowser = true } label: {
                            Image(systemName: "folder")
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { showMoveAlert = false }

                Button("Move") {
                    Task {
                        await performMove()
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(moveLocation.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
        #endif
    }
    
    var fileBrowserSheet: some View {
        #if os(iOS)
        NavigationView {
            FileBrowserView(
                currentPath: moveLocation,
                basePath: store.selection?.pathFilesystem ?? "",
                server: store.selection,
                onFolderSelected: { folderPath in
                    moveLocation = folderPath
                    showFileBrowser = false
                }
            ).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            showFileBrowser = false
                        }
                    }
                }
        }
        .presentationDetents([.large])
        #else
        FileBrowserView(
            currentPath: moveLocation,
            basePath: store.selection?.pathFilesystem ?? "",
            server: store.selection,
            onFolderSelected: { folderPath in
                moveLocation = folderPath
                showFileBrowser = false
            }
        ).frame(width: 600, height: 600)
        #endif
    }
}

#if os(iOS)
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .resizable()
                .frame(width: 20, height: 20).padding(10)
                .foregroundColor(.accentColor)
                .onTapGesture {
                    withAnimation(.spring()) {
                        configuration.isOn.toggle()
                    }
                }

            configuration.label
        }
    }
}
#endif
