import SwiftUI

struct DetailsView: View {
    @ObservedObject var store: Store
    @ObservedObject var manager: TorrentManager
    @State private var showTrackers = false
    @State private var showFiles = false
    @State private var isUpdatingFiles = false
    @State private var unwantedFiles: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    
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
        if let selectedTorrentId = store.selectedTorrentId,
           let torrent = manager.torrents.first(where: { $0.id == selectedTorrentId }) {
            Text(torrent.name ?? "Torrent")
                .font(.headline)
                .padding()
                .padding(.bottom, 0)
            Divider()
                .padding(.bottom, 0)
            ScrollView {
                VStack(spacing: 16) {
                    // Basic Info
                    DetailSection(title: "Status") {
                        VStack(spacing: 12) {
                            InfoRow(
                                icon: "gauge",
                                title: "Progress",
                                value: "\(Int((torrent.percentDone ?? 0) * 100))%"
                            )
                            
                            InfoRow(
                                icon: "clock",
                                title: "Status",
                                value: getStatusText(torrent.status)
                            )
                            
                            if let error = torrent.error, error > 0 {
                                InfoRow(
                                    icon: "exclamationmark.triangle",
                                    title: "Error",
                                    value: torrent.errorString ?? "Unknown error"
                                )
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
                    // Files
                    DetailSection(title: "Files") {
                        if let selectedTorrentId = store.selectedTorrentId,
                           let torrent = manager.torrents.first(where: { $0.id == selectedTorrentId }) {
                            DisclosureGroup(isExpanded: $showFiles) {
                                Text("Tap a file or folder to toggle download").font(.caption).padding(.bottom,10)
                                TorrentFilesView(torrent: torrent, manager: manager)
                            } label: {
                                Text("Show / Manage Files")
                            }
                        }
                    }
                    
                    // Trackers
                    DetailSection(title: "Trackers") {
                        DisclosureGroup(isExpanded: $showTrackers) {
                            if let trackerStats = torrent.trackerStats {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(trackerStats.indices, id: \.self) { index in
                                        if let tracker = trackerStats[index] as? [String: Any],
                                           let host = tracker["host"] as? String {
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
                .padding()
            }
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
            ContentUnavailableView("Select a Torrent",
                                 systemImage: "arrow.up.and.down.square",
                                 description: Text("Select a torrent to view Details.")
            )
        }
    }
    
    var body: some View {
        torrentDetails
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
