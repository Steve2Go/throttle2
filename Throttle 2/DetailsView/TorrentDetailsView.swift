import SwiftUI
import SimpleToast
#if os(iOS)
import UIKit
#endif

struct DetailsView: View {
    @ObservedObject var store: Store
    @ObservedObject var manager: TorrentManager

    @State private var showTrackers = false
    @State private var showFiles = false
    @State private var isUpdatingFiles = false
    @State private var unwantedFiles: Set<Int> = []
    @State var showBrowser = false
    @State var torrentUrl: String?
    @State private var isLoadingPath = false
    @Environment(\.dismiss) private var dismiss
    @State private var detailedTorrent: Torrent?
    @State var magnet = ""
    @State var showToast = false
    @State var fileStat: TorrentResponse?
    @State private var sheetUnwantedFiles: Set<Int> = []
    @State private var sheetFileTree: [FileNode] = []
    @State private var isBuildingFileTree: Bool = false
    
    private let toastOptions = SimpleToastOptions(
            hideAfter: 5
        )
    
    
    private func isFileWanted(_ index: Int) -> Bool {
        !unwantedFiles.contains(index)
    }
    
    private func getAllFileIndices(_ node: FileNode) -> [Int] {
        var indices: [Int] = []
        if let fileIndex = node.fileIndex {
            indices.append(fileIndex)
        }
        for child in node.children {
            indices.append(contentsOf: getAllFileIndices(child))
        }
        return indices
    }
    private func toggleNode(_ node: FileNode) async {
        guard let torrentId = store.selectedTorrentId else { return }
        
        if node.isDirectory {
            // Get all file indices in this directory
            let indices = getAllFileIndices(node)
            // Check if all files are currently wanted
            let allWanted = indices.allSatisfy { isFileWanted($0) }
            // Toggle all files to the opposite state
            try? await manager.setTorrentFiles(
                id: torrentId,
                wanted: allWanted ? nil : indices,
                unwanted: allWanted ? indices : nil
            )
            // Update local state
            if allWanted {
                unwantedFiles.formUnion(indices)
            } else {
                unwantedFiles.subtract(indices)
            }
        } else if let fileIndex = node.fileIndex {
            // Toggle single file
            let isWanted = isFileWanted(fileIndex)
            try? await manager.setTorrentFiles(
                id: torrentId,
                wanted: isWanted ? nil : [fileIndex],
                unwanted: isWanted ? [fileIndex] : nil
            )
            // Update local state
            if isWanted {
                unwantedFiles.insert(fileIndex)
            } else {
                unwantedFiles.remove(fileIndex)
            }
        }
    }
    
    private func formatBytes(_ byteCount: Int64?) -> String {
        guard let byteCount = byteCount else { return "0 B" }
        let sizes = ["B", "KB", "MB", "GB", "TB"]
        var convertedCount = Double(byteCount)
        var index = 0
        
        while convertedCount >= 1024 && index < sizes.count - 1 {
            convertedCount /= 1024
            index += 1
        }
        
        return String(format: "%.2f %@", convertedCount, sizes[index])
    }
    
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "N/A" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    
    private func getStatusText(_ status: Int?) -> String {
        guard let status = status else { return "Unknown" }
        switch status {
        case 0: return "Stopped"
        case 1: return "Queued to verify"
        case 2: return "Verifying"
        case 3: return "Queued to download"
        case 4: return "Downloading"
        case 5: return "Queued to seed"
        case 6: return "Seeding"
        default: return "Unknown"
        }
    }
    
    private func processFolder(files: [(index: Int, file: TorrentFile)], path: String = "") -> [TorrentFileNode] {
        var result: [TorrentFileNode] = []
        var subfolders: [String: [(index: Int, file: TorrentFile)]] = [:]
        
        // First sort files into this level vs subfolders
        for file in files {
            let relativePath = file.file.name.hasPrefix(path) ? String(file.file.name.dropFirst(path.isEmpty ? 0 : path.count + 1)) : file.file.name
            let components = relativePath.split(separator: "/")
            
            if components.count == 1 {
                // This is a file at this level
                result.append(TorrentFileNode(
                    filename: String(components[0]),
                    path: file.file.name,
                    isDirectory: false,
                    fileIndex: file.index,
                    length: file.file.length,
                    progress: file.file.progress,
                    children: []
                ))
            } else {
                // This belongs in a subfolder
                let folderName = String(components[0])
                if subfolders[folderName] == nil {
                    subfolders[folderName] = []
                }
                subfolders[folderName]?.append(file)
            }
        }
        
        // Process subfolders
        for (folderName, folderFiles) in subfolders {
            let folderPath = path.isEmpty ? folderName : "\(path)/\(folderName)"
            let children = processFolder(files: folderFiles, path: folderPath)
            result.append(TorrentFileNode(
                filename: folderName,
                path: folderPath,
                isDirectory: true,
                fileIndex: nil,
                length: nil,
                progress: nil,
                children: children
            ))
        }
        
        return result.sorted { $0.filename < $1.filename }
    }

    private func buildFileTree(from files: [TorrentFile], fileStats: [[String: Any]]) -> [TorrentFileNode] {
        // Create index/file pairs
        let indexedFiles = files.enumerated().map { ($0.offset, $0.element) }
        return processFolder(files: indexedFiles)
    }
    
    
    func getAllFileIndices(_ node: TorrentFileNode) -> [Int] {
        var indices: [Int] = []
        if let fileIndex = node.fileIndex {
            indices.append(fileIndex)
        }
        for child in node.children {
            indices.append(contentsOf: getAllFileIndices(child))
        }
        return indices
    }

    func toggleNode(_ node: TorrentFileNode) async {
        guard let torrentId = store.selectedTorrentId else { return }
        
        if node.isDirectory {
            // Get all file indices in this directory
            let indices = getAllFileIndices(node)
            // Check if all files are currently wanted
            let allWanted = indices.allSatisfy { isFileWanted($0) }
            // Toggle all files to the opposite state
            try? await manager.setTorrentFiles(
                id: torrentId,
                wanted: allWanted ? nil : indices,
                unwanted: allWanted ? indices : nil
            )
            // Update local state
            if allWanted {
                unwantedFiles.formUnion(indices)
            } else {
                unwantedFiles.subtract(indices)
            }
        } else if let fileIndex = node.fileIndex {
            // Toggle single file
            let isWanted = isFileWanted(fileIndex)
            try? await manager.setTorrentFiles(
                id: torrentId,
                wanted: isWanted ? nil : [fileIndex],
                unwanted: isWanted ? [fileIndex] : nil
            )
            // Update local state
            if isWanted {
                unwantedFiles.insert(fileIndex)
            } else {
                unwantedFiles.remove(fileIndex)
            }
        }
    }

    
    @ViewBuilder
    private func InfoRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
    
    struct DetailSection<Content: View>: View {
        let title: String
        let content: Content
        
        init(title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }
        
        var body: some View {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 4)
                content
            }
            .padding()
            #if os(iOS)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            #endif
            .cornerRadius(10)
        }
    }
    
    @ViewBuilder
    private var torrentDetails: some View {
        if let _ = store.selectedTorrentId,
           let torrent = detailedTorrent {
     
                
                Text(torrent.name ?? "Torrent")
                    .font(.headline)
                    .padding()
                    .padding(.bottom, 0)
    
            Divider()
                .padding(.bottom, 0)
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
#if os(macOS)
                        Button("Close" ,systemImage: "xmark"){
    store.selectedTorrentId = nil
}
#endif
#if os(iOS)
Spacer()
#endif
                    // torrent download
                    Button("Magnet", systemImage: "document.on.document"){
                        #if os(iOS)
                        UIPasteboard.general.string = magnet
                        #else
                        NSPasteboard.general.setString(magnet, forType: .string)
                        #endif
                        showToast.toggle()
                    }
                        #if os(iOS)
                    .padding(.trailing,15)
#endif
                    
                    // button for downloading the torrent file
                    if let torrentFileValue = detailedTorrent?.dynamicFields["torrentFile"]?.value as? String {
                        Button(".torrent", systemImage: "arrow.down.doc") {
                            Task {
                                do {
                                    let data: Data
                                    // Try decoding as Base64 first; if that fails, try using UTF-8 conversion.
                                    if let base64Data = Data(base64Encoded: torrentFileValue) {
                                        data = base64Data
                                    } else if let stringData = torrentFileValue.data(using: .utf8) {
                                        data = stringData
                                    } else {
                                        print("Failed to convert torrent file content to data")
                                        return
                                    }
                                    
#if os(iOS)
                                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent((detailedTorrent?.name ?? "torrent") + ".torrent")
                                    try data.write(to: tempURL)
                                    let picker = UIDocumentPickerViewController(forExporting: [tempURL])
                                    DispatchQueue.main.async {
                                        let keyWindow = UIApplication.shared.connectedScenes
                                            .compactMap { $0 as? UIWindowScene }
                                            .flatMap { $0.windows }
                                            .first { $0.isKeyWindow }
                                        if var topController = keyWindow?.rootViewController {
                                            while let presented = topController.presentedViewController {
                                                topController = presented
                                            }
                                            topController.present(picker, animated: true)
                                        }
                                    }
#else
                                    let panel = NSSavePanel()
                                    panel.title = "Save Torrent File"
                                    panel.allowedFileTypes = ["torrent"]
                                    panel.nameFieldStringValue = (detailedTorrent?.name ?? "torrent") + ".torrent"
                                    
                                    if panel.runModal() == .OK, let saveURL = panel.url {
                                        try data.write(to: saveURL)
                                    }
#endif
                                } catch {
                                    print("Failed to save torrent file:", error.localizedDescription)
                                }
                            }
                            }
                        }
                    }
                
                // Transfer Info
                DetailSection(title: "Transfer") {
                    VStack(spacing: 12) {
                        let downloadedEver = (torrent.dynamicFields["downloadedEver"]?.value as? Int64) ??
                                           (torrent.dynamicFields["downloadedEver"]?.value as? Int).map(Int64.init) ?? 0
                        
                        let uploadedEver = (torrent.dynamicFields["uploadedEver"]?.value as? Int64) ??
                                         (torrent.dynamicFields["uploadedEver"]?.value as? Int).map(Int64.init) ?? 0
                        
                        let totalSize = (torrent.dynamicFields["totalSize"]?.value as? Int64) ??
                                      (torrent.dynamicFields["totalSize"]?.value as? Int).map(Int64.init) ?? 0
                        
                        InfoRow(
                            icon: "arrow.down",
                            title: "Downloaded",
                            value: formatBytes(downloadedEver)
                        )
                        
                        InfoRow(
                            icon: "arrow.up",
                            title: "Uploaded",
                            value: formatBytes(uploadedEver)
                        )
                        
                        InfoRow(
                            icon: "externaldrive",
                            title: "Total Size",
                            value: formatBytes(totalSize)
                        )
                        
                        if let ratio = torrent.dynamicFields["uploadRatio"]?.value as? Double {
                            InfoRow(
                                icon: "arrow.up.arrow.down",
                                title: "Ratio",
                                value: String(format: "%.2f", ratio)
                            )
                        }
                    }
                }
                
                // Dates
                DetailSection(title: "Dates") {
                    VStack(spacing: 12) {
                        InfoRow(
                            icon: "calendar",
                            title: "Added",
                            value: formatDate(torrent.addedDate)
                        )
                        
                        InfoRow(
                            icon: "clock",
                            title: "Last Active",
                            value: formatDate(torrent.activityDate)
                        )
                    }
                }
                    // Files
                    DetailSection(title: "Files") {
                        if let torrentFiles = detailedTorrent?.files,
                           let fileStats = detailedTorrent?.dynamicFields["fileStats"]?.value as? [[String: Any]] {
                            // Convert wanted state from fileStats
                            let wantedSet: Set<Int> = Set(fileStats.enumerated().compactMap { (i, stat) in
                                let wanted = stat["wanted"] as? Bool ?? true
                                return wanted ? nil : i
                            })
                            let selectedCount = torrentFiles.count - unwantedFiles.count
                            let totalCount = torrentFiles.count
                            HStack {
                                Image(systemName:"checklist")
                                Button("\(selectedCount) of \(totalCount) files Active") {
                                    isBuildingFileTree = true
                                    sheetUnwantedFiles = unwantedFiles
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let fileTreeCopy = torrentFiles.enumerated().map { (i, file) in (i, file) }.toFileTree()
                                        DispatchQueue.main.async {
                                            sheetFileTree = fileTreeCopy
                                            isBuildingFileTree = false
                                            showFiles = true
                                        }
                                    }
                                }
                                
                                Spacer()
                            }
                            .overlay(
                                Group {
                                    if isBuildingFileTree {
                                        ProgressView("Building file list...")
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(Color.black.opacity(0.2))
                                    }
                                }
                            )
                            .sheet(isPresented: $showFiles) {
                                FileSelectionView(
                                    fileTree: sheetFileTree,
                                    initialUnwanted: sheetUnwantedFiles,
                                    onSave: { newUnwanted in
                                        Task {
                                            unwantedFiles = newUnwanted
                                            try? await manager.setTorrentFiles(
                                                id: store.selectedTorrentId!,
                                                wanted: Array(0..<torrentFiles.count).filter { !newUnwanted.contains($0) },
                                                unwanted: Array(newUnwanted)
                                            )
                                            showFiles = false
                                        }
                                    },
                                    onCancel: {
                                        showFiles = false
                                    }
                                )
                                #if os(macOS)
                                .frame(width:400, height: 500)
                                #endif
                            }
                        }
                    }
                    
                    
                
//                // Files
//                DetailSection(title: "Files") {
//                    
////                    if let selectedTorrentId = store.selectedTorrentId,
////                       let torrentFiles = detailedTorrent?.files,
////                       let fileStats = detailedTorrent?.dynamicFields["fileStats"]?.value as? [[String: Any]] {
////                        DisclosureGroup(isExpanded: $showFiles) {
////                            ForEach(torrentFiles.indices, id: \.self) { index in
////                                if index < fileStats.count {
////                                    let file = torrentFiles[index]
////                                    let fileStat = fileStats[index]
////                                    let isWanted = fileStat["wanted"] as? Bool ?? true
////                                    
////                                    Button(action: {
////                                        // Toggle file selection
////                                        Task {
////                                            // If wanted, make unwanted (and vice versa)
////                                            try? await manager.setTorrentFiles(
////                                                id: selectedTorrentId,
////                                                wanted: isWanted ? nil : [index],
////                                                unwanted: isWanted ? [index] : nil
////                                            )
////                                            
////                                            // Refresh torrent details after changing selection
////                                            try? await detailedTorrent = manager.fetchTorrentDetails(id: selectedTorrentId)
////                                        }
////                                    }) {
////                                        VStack(alignment: .leading, spacing: 4) {
////                                            HStack {
////                                                Image(systemName: isWanted ? "checkmark.circle.fill" : "xmark.circle.fill")
////                                                    .foregroundColor(isWanted ? .green : .red)
////                                                
////                                                Text(file.name)
////                                                    .lineLimit(1)
////                                                    .truncationMode(.middle)
////                                                
////                                                Spacer()
////                                                
////                                                Text(formatBytes(file.length))
////                                                    .font(.caption)
////                                                    .foregroundStyle(.secondary)
////                                            }
////                                            
////                                            ProgressView(value: file.progress)
////                                                .progressViewStyle(.linear)
////                                                .frame(height: 6)
////                                            
////                                            Text("\(Int(file.progress * 100))% complete")
////                                                .font(.caption)
////                                                .foregroundStyle(.secondary)
////                                        }
////                                    }
////                                    .buttonStyle(PlainButtonStyle())
////                                    .padding(.vertical, 4)
////                                    
////                                    if index < torrentFiles.count - 1 {
////                                        Divider()
////                                    }
////                                }
////                            }
////                        } label: {
////                            Text("Show / Manage Files")
////                        }
////                    }
//                }
                
                // Trackers
                DetailSection(title: "Trackers") {
                    DisclosureGroup(isExpanded: $showTrackers) {
                        if let trackerStats = torrent.trackerStats {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(trackerStats.indices, id: \.self) { index in
                                    let tracker = trackerStats[index]
                                    if let host = tracker["host"] as? String {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(host)
                                                .font(.subheadline)
                                            if let lastAnnounceResult = tracker["lastAnnounceResult"] as? String {
                                                Text(lastAnnounceResult)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        if index < trackerStats.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .padding(.vertical)
                        }
                    } label: {
                        Text("Show Trackers")
                    }
                }
            }
                .simpleToast(isPresented: $showToast, options: toastOptions) {
                    Label("Text Copied", systemImage: "document.on.document")
                    .padding()
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(Color.white)
                    .cornerRadius(10)
                    .padding(.top)
                }
                
                .padding()
            }.sheet(isPresented: $showBrowser, content: {
                Group {
                    if let url = torrentUrl, let torrentName = torrent.name {
                        #if os(iOS)
                        SFTPFileBrowserView(
                            currentPath: url + "/" + torrentName,
                            basePath: (store.selection?.pathServer) ?? "",
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
            
            
            #if os(iOS)
            .navigationTitle("Torrent Details")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
            }
            #endif

        } else {
            if( store.selectedTorrentId != nil) {
                ProgressView()
            }else{
                ContentUnavailableView("Select a Torrent",
                                       systemImage: "arrow.up.and.down.square",
                                       description: Text("Select a torrent to view Details.")
                )
            }
        }
        
    }

    var body: some View {
        torrentDetails
            .onAppear() {
                Task {
                    if store.selectedTorrentId != nil{
                        try await detailedTorrent = manager.fetchTorrentDetails(id: store.selectedTorrentId!)
                        magnet = detailedTorrent?.dynamicFields["magnetLink"]?.value as? String ?? ""
                        if let torrentFiles = detailedTorrent?.files {
                            // fileTree = torrentFiles.enumerated().map { (i, file) in (i, file) }.toFileTree()
                        } else {
                            // fileTree = []
                        }
                    }
                }
            }
            .onChange(of: store.selectedTorrentId, {
                Task {
                    try await detailedTorrent = manager.fetchTorrentDetails(id: store.selectedTorrentId ?? 0)
                    magnet = detailedTorrent?.dynamicFields["magnetLink"]?.value as? String ?? ""
                    if let torrentFiles = detailedTorrent?.files {
                        // fileTree = torrentFiles.enumerated().map { (i, file) in (i, file) }.toFileTree()
                    } else {
                        // fileTree = []
                    }
                }
            })
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct TorrentFileNode: Identifiable, Hashable {
    let id: String
    let filename: String
    let path: String
    let isDirectory: Bool
    let fileIndex: Int?
    let length: Int64?
    let progress: Double?
    var children: [TorrentFileNode]
    
    static func == (lhs: TorrentFileNode, rhs: TorrentFileNode) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    init(filename: String, path: String, isDirectory: Bool = false, fileIndex: Int? = nil, length: Int64? = nil, progress: Double? = nil, children: [TorrentFileNode] = []) {
        self.id = path
        self.filename = filename
        self.path = path
        self.isDirectory = isDirectory
        self.fileIndex = fileIndex
        self.length = length
        self.progress = progress
        self.children = children
    }
}

struct TorrentFileNodeView: View {
    let node: TorrentFileNode
    let level: Int
    let isWanted: (Int) -> Bool
    let toggleNode: (TorrentFileNode) async -> Void
    let formatBytes: (Int64?) -> String
    
    private var folderStatus: (icon: String, color: Color) {
        if node.isDirectory {
            // Get all file indices in this folder and subfolders
            let indices = getAllFileIndices(node)
            let allOn = indices.allSatisfy { isWanted($0) }
            let allOff = indices.allSatisfy { !isWanted($0) }
            
            if allOn {
                return ("checkmark.circle.fill", .green)
            } else if allOff {
                return ("xmark.circle.fill", .red)
            } else {
                return ("minus.circle.fill", .blue)
            }
        }
        return ("folder.fill", .blue)  // Default, though should never be used
    }
    
    private func getAllFileIndices(_ node: TorrentFileNode) -> [Int] {
        var indices: [Int] = []
        if let fileIndex = node.fileIndex {
            indices.append(fileIndex)
        }
        for child in node.children {
            indices.append(contentsOf: getAllFileIndices(child))
        }
        return indices
    }
    
    var body: some View {
        if node.isDirectory {
            DisclosureGroup {
                ForEach(node.children.sorted(by: { $0.filename < $1.filename })) { child in
                    TorrentFileNodeView(
                        node: child,
                        level: level + 1,
                        isWanted: isWanted,
                        toggleNode: toggleNode,
                        formatBytes: formatBytes
                    )
                }
            } label: {
                Button(action: {
                    Task {
                        await toggleNode(node)
                    }
                }) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.blue)
                        Image(systemName: folderStatus.icon)
                            .foregroundColor(folderStatus.color)
                        Text(node.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, CGFloat(level * 20))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: {
                    Task {
                        await toggleNode(node)
                    }
                }) {
                    HStack {
                        Image(systemName: isWanted(node.fileIndex ?? -1) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isWanted(node.fileIndex ?? -1) ? .green : .red)
                        Text(node.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(node.length))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, CGFloat(level * 20))
                
                if let progress = node.progress {
                    VStack(alignment: .leading) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(height: 6)
                        Text("\(Int(progress * 100))% complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(level * 20 + 24))
                }
            }
        }
    }
}
