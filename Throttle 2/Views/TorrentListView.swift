import SwiftUI
import SimpleToast
import CoreData

struct AnyViewModifier: ViewModifier {
    let modifier: (Content) -> any View
    
    init<M: ViewModifier>(_ modifier: M) {
        self.modifier = { content in
            content.modifier(modifier)
        }
    }
    
    func body(content: Content) -> some View {
        AnyView(modifier(content))
    }
}

// MARK: - Views
struct TorrentListView: View {
    @ObservedObject var manager: TorrentManager
    var baseURL: URL
    @State var rotation: Double = 0
    @State var sortOption: SortOption = SortOption.loadFromDefaults()
//    @Query var servers: [Servers]
    @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Servers.name, ascending: true)],
            animation: .default)
        private var servers: FetchedResults<Servers>
    @Binding var activeSheet: ActiveSheet?
    @ObservedObject var store: Store
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
    private let toastOptions = SimpleToastOptions(
        hideAfter: 5
    )
    
    var sortedTorrents: [Torrent] {
        let filtered = manager.torrents.filter { torrent in
            searchQuery.isEmpty || (torrent.name?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
        
        switch sortOption {
        case .name:
            return filtered.sorted { ($0.name ?? "") < ($1.name ?? "") }
        case .dateAdded:
            return filtered.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        case .activity:
            return filtered.sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
        }
    }
    
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
    
    @ViewBuilder
    func torrentContextMenu(_ torrent: Torrent) -> some View {
        Button(role: .destructive) {
            deleteTorrent(torrent)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        
        Button {
            setupMutation(torrent)
            mutateTorrent?.move()
        } label: {
            Label("Move", systemImage: "folder")
        }
        
        Button {
            setupMutation(torrent)
            mutateTorrent?.rename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        
        if torrent.progress < 1.0 {
            Divider()
            Button {
                // Priority actions - to be implemented
            } label: {
                Label("Set Priority", systemImage: "arrow.up.arrow.down")
            }
        }
    }
    
    @ViewBuilder
    func torrentRow(_ torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(torrent.name?.truncatedMiddle() ?? "Loading...")
            
            HStack {
                ProgressView(value: torrent.progress) {
                    Text("\(Int(torrent.progress * 100))%")
                        .font(.caption)
                }
                .tint(torrent.progress >= 1.0 ? .green : .blue)
                
                Button {
                    Task {
                        try? await manager.toggleStar(for: torrent.id)
                    }
                } label: {
                    Image(systemName: manager.isStarred(torrent.id) ? "star.fill" : "star")
                        .foregroundStyle(manager.isStarred(torrent.id) ? .yellow : .gray)
                }
                .buttonStyle(.plain)
            }
            
            if let downloaded = torrent.downloadedEver,
               let total = torrent.totalSize {
                Text("Downloaded: \(formatBytes(downloaded)) / \(formatBytes(total))")
                    .font(.caption)
            }
            
            if let error = torrent.error, error != 0 {
                Text(torrent.errorString ?? "Unknown error")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            torrentContextMenu(torrent)
        }
        #if os(iOS)
        
        
        #endif
    }
   
    
    var body: some View {
        Text("Test")
        //
        //        ScrollView {
        //            LazyVStack {
        //            ForEach(sortedTorrents) { torrent in
        //                TorrentRowView(
        //                    manager: manager,
        //                    store: store,
        //                    torrent: torrent,
        //                    onDelete: { deleteTorrent(torrent) },
        //                    onMove: {
        //                        setupMutation(torrent)
        //                        mutateTorrent?.move()
        //                    },
        //                    onRename: {
        //                        setupMutation(torrent)
        //                        mutateTorrent?.rename()
        //                    }
        //                )
        //                .onTapGesture {
        //                    store.selectedTorrentId = torrent.id
        //#if os(iOS)
        //                    showDetailsSheet = true
        //#endif
        //                }
        //            }
        //            //}
        //       
        //        }
        //        
        //    }
        //        .simpleToast(isPresented: $store.showToast, options: toastOptions) {
        //            Label("Request Complete", systemImage: "rectangle.connected.to.line.below")
        //            .padding()
        //            .background(Color.white)
        //            .foregroundColor(Color.green)
        //            .cornerRadius(10)
        //            .padding(.top)
        //        }
        //        .sheet(isPresented: $showRenameAlert) {
        //            #if os(iOS)
        //            NavigationView {
        //                Form {
        //                    Section("Current Name") {
        //                        Text(selectedTorrent?.name ?? "")
        //                            .foregroundStyle(.secondary)
        //                    }
        //                    
        //                    Section("New Name") {
        //                        HStack {
        //                            TextField("Enter new name", text: $renameText)
        //                                .autocorrectionDisabled()
        //                                .autocapitalization(.none)
        //                            
        //                            Button("Rename") {
        //                                if let torrent = selectedTorrent {
        //                                    Task {
        //                                        do {
        //                                            try await manager.renamePath(
        //                                                ids: [torrent.id],
        //                                                path: torrent.name ?? "",
        //                                                newName: renameText
        //                                            )
        //                                        } catch {
        //                                            print("Error renaming torrent:", error)
        //                                        }
        //                                    }
        //                                }
        //                                showRenameAlert = false
        //                            }
        //                            .buttonStyle(.borderedProminent)
        //                            .disabled(renameText.isEmpty)
        //                        }
        //                    }
        //                }
        //                .navigationTitle("Rename Torrent")
        //                .toolbar {
        //                    ToolbarItem(placement: .cancellationAction) {
        //                        Button("Cancel") {
        //                            showRenameAlert = false
        //                        }
        //                    }
        //                }
        //                .presentationDetents([.medium])
        //                .presentationDragIndicator(.visible)
        //            }
        //            #else
        //            VStack(spacing: 12) {
        //                Text("Current name:")
        //                    .frame(maxWidth: .infinity, alignment: .leading)
        //                Text(selectedTorrent?.name ?? "")
        //                    .frame(maxWidth: .infinity, alignment: .leading)
        //                    .foregroundStyle(.secondary)
        //                
        //                Divider()
        //                
        //                HStack {
        //                    TextField("New name", text: $renameText)
        //                        .textFieldStyle(.roundedBorder)
        //                        .frame(maxWidth: .infinity)
        //                    
        //                    Button("Rename") {
        //                        if let torrent = selectedTorrent {
        //                            Task {
        //                                do {
        //                                    try await manager.renamePath(
        //                                        ids: [torrent.id],
        //                                        path: torrent.name ?? "",
        //                                        newName: renameText
        //                                    )
        //                                } catch {
        //                                    print("Error renaming torrent:", error)
        //                                }
        //                            }
        //                        }
        //                        showRenameAlert = false
        //                    }
        //                    .keyboardShortcut(.return)
        //                    .disabled(renameText.isEmpty)
        //                }
        //            }
        //            .padding()
        //            .frame(width: 400)
        //            #endif
        //        }
        //        
        //        .onChange(of: sortOption) { _ in
        //            print("Sort option changed to: \(sortOption.rawValue)")
        //        }
        //        .refreshable {
        //            Task {
        //                try? await manager.fetchUpdates(fields: [
        //                    "id", "name", "percentDone", "percentComplete", "status",
        //                    "downloadedEver", "uploadedEver", "totalSize",
        //                    "error", "errorString", "files", "labels"
        //                ], isFullRefresh: true)
        //            }
        //        }
        //#if os(iOS)
        //.sheet(isPresented: $showDetailsSheet) {
        //    NavigationStack {
        //        DetailsView(store: store, manager: manager)
        //                }
        //}
        //#endif
        //.searchable(text: $searchQuery, prompt: "Search")
        //        .toolbar {
        //            if store.sideBar == false {
        //                ToolbarItemGroup(placement: .automatic) {
        //                    Menu {
        //                        ForEach(servers) { server in
        //                            Button(action: {
        //                                store.selection = server
        //                            }, label: {
        //                                if store.selection == server {
        //                                    Image(systemName: "checkmark.circle").padding(.leading, 6)
        //                                } else {
        //                                    Image(systemName: "circle")
        //                                }
        //                                Text(server.isDefault ? server.name + " (Default)" : server.name)
        //                            })
        //                            .buttonStyle(.plain)
        //                        }
        //                    } label: {
        //                        Image(systemName: "rectangle.connected.to.line.below")
        //                    }
        //                }
        //            }
        //                #if os(iOS)
        //            
        //                
        //            ToolbarItemGroup(placement: .navigationBarTrailing) {
        //                Menu {
        //                    Button(action: {
        //                        activeSheet = .servers
        //                    }, label: {
        //                        Image(systemName: "rectangle.connected.to.line.below").padding(.leading, 6)
        //                        Text("Manage Servers")
        //                    })
        //                    .buttonStyle(.plain)
        //                    
        //                    Button(action: {
        //                        activeSheet = .settings
        //                    }, label: {
        //                        Image(systemName: "gearshape").padding(.leading, 6)
        //                        Text("Settings")
        //                    })
        //                    .buttonStyle(.plain)
        //                    
        //                } label: {
        //                    Image(systemName: "gearshape")
        //                }}
        //                
        //                #endif
        //            
        //            #if os(macOS)
        //            ToolbarItemGroup(placement: .automatic) {
        //                Button(action: {
        //                    Task {
        //                        try? await manager.fetchUpdates(fields: [
        //                            "id", "name", "percentDone", "percentComplete", "status",
        //                            "downloadedEver", "uploadedEver", "totalSize",
        //                            "error", "errorString", "files", "labels"
        //                        ], isFullRefresh: true)
        //                    }
        //                }) {
        //                    if manager.isLoading {
        //                        Image(systemName: "arrow.trianglehead.2.clockwise")
        //                            .rotationEffect(.degrees(rotation))
        //                            .onAppear {
        //                                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
        //                                    rotation = 360
        //                                }
        //                            }
        //                    } else {
        //                        Image(systemName: "arrow.trianglehead.2.clockwise")
        //                    }
        //                }
        //                .disabled(manager.isLoading)
        //            }
        //            #endif
        //            
        //            
        //            
        //            ToolbarItemGroup(placement: .primaryAction) {
        //                Menu {
        //                    ForEach(SortOption.allCases, id: \.self) { option in
        //                        Button(action: {
        //                            sortOption = option
        //                            SortOption.saveToDefaults(option)
        //                        }) {
        //                            HStack {
        //                                Text(option.rawValue)
        //                                if sortOption == option {
        //                                    Image(systemName: "checkmark.circle")
        //                                } else {
        //                                    Image(systemName: "circle")
        //                                }
        //                            }
        //                        }
        //                    }
        //                } label: {
        //                    Image(systemName: "arrow.up.and.down.text.horizontal")
        //                }
        //            }
        //        
        //        }
        //        .onChange(of: baseURL) { newURL in
        //            print("🔄 Server URL changed to:", newURL.absoluteString)
        //            manager.updateBaseURL(newURL)
        //            manager.stopPeriodicUpdates()
        //            manager.reset()
        //            Task {
        //                try? await manager.fetchUpdates(fields: [
        //                    "id", "name", "percentDone", "percentComplete", "status",
        //                    "downloadedEver", "uploadedEver", "totalSize",
        //                    "error", "errorString", "files", "labels"
        //                ])
        //            }
        //            manager.startPeriodicUpdates()
        //        }
        //        .onAppear {
        //            print("🚀 View appeared, starting periodic updates")
        //            manager.startPeriodicUpdates()
        //        }
        //        .onDisappear {
        //            print("👋 View disappeared, stopping updates")
        //            manager.stopPeriodicUpdates()
        //        }
        //        .sheet(isPresented: $showDeleteSheet) {
        //            if let deleteSheet = deleteSheet {
        //                deleteSheet.sheet
        //                    #if os(iOS)
        //                    .presentationDetents([.medium])
        //                    .presentationDragIndicator(.visible)
        //                    #endif
        //            }
        //        }.presentationDetents([.medium])
        //        .sheet(isPresented: $showMoveSheet) {
        //                    if let mutateTorrent = mutateTorrent {
        //                        mutateTorrent.moveSheet
        //                            #if os(iOS)
        //                            .presentationDetents([.medium])
        //                            .presentationDragIndicator(.visible)
        //                            #endif
        //                    }
        //                }
        //        
        //    }
        //
    }  /// this one was added
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// String extension
extension String {
    func truncatedMiddle() -> String {
        guard self.count > 45 else { return self }
        let prefix = String(self.prefix(25))
        let suffix = String(self.suffix(10))
        return "\(prefix)...\(suffix)"
    }
}
extension String {
    func truncatedMiddleMore() -> String {
        guard self.count > 30 else { return self }
        let prefix = String(self.prefix(15))
        let suffix = String(self.suffix(10))
        return "\(prefix)...\(suffix)"
    }
}
