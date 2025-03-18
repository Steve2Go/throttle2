import SwiftUI

struct TorrentRowView: View {
    @ObservedObject var manager: TorrentManager
    @ObservedObject var store: Store
    let torrent: Torrent
    let onDelete: () -> Void
    let onMove: () -> Void
    let onRename: () -> Void
    
    var body: some View {
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
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            
            Button {
                onMove()
            } label: {
                Label("Move", systemImage: "folder")
            }
            
            Button {
                onRename()
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
    }
}