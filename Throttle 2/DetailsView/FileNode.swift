import SwiftUI

struct FileNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileNode]
    let fileIndex: Int?
    let length: Int64?
    let bytesCompleted: Int64?
    
    var progress: Double {
        if isDirectory {
            guard !children.isEmpty else { return 0 }
            let totalProgress = children.reduce(0.0) { $0 + $1.progress }
            return totalProgress / Double(children.count)
        } else {
            guard let length = length, length > 0 else { return 0 }
            return Double(bytesCompleted ?? 0) / Double(length)
        }
    }
}

//extension Array where Element == TorrentFile {
//    func toFileTree() -> [FileNode] {
//        var nodes: [String: FileNode] = [:]
//        
//        // First pass: Create all directory nodes
//        for (index, file) in self.enumerated() {
//            let components = file.name.split(separator: "/")
//            
//            // Create directory nodes
//            for (i, component) in components.dropLast().enumerated() {
//                let dirPath = String(components[...i].joined(separator: "/"))
//                
//                if nodes[dirPath] == nil {
//                    nodes[dirPath] = FileNode(
//                        id: dirPath,
//                        name: String(component),
//                        path: dirPath,
//                        isDirectory: true,
//                        children: [],
//                        fileIndex: nil,
//                        length: nil,
//                        bytesCompleted: nil
//                    )
//                }
//            }
//            
//            // Create file node
//            let filePath = file.name
//            nodes[filePath] = FileNode(
//                id: filePath,
//                name: String(components.last!),
//                path: filePath,
//                isDirectory: false,
//                children: [],
//                fileIndex: index,
//                length: file.length,
//                bytesCompleted: file.bytesCompleted
//            )
//        }
//        
//        // Second pass: Build the tree structure
//        for (path, node) in nodes {
//            if node.isDirectory {
//                let dirPath = path + "/"
//                let children = nodes.filter {
//                    $0.key.hasPrefix(dirPath) &&
//                    $0.key.drop(while: { $0 != "/" }).dropFirst().contains("/") == false
//                }
//                nodes[path]?.children = children.values.sorted { $0.name < $1.name }
//            }
//        }
//        
//        return nodes.values.filter { !$0.path.contains("/") }.sorted { $0.name < $1.name }
//    }
//}
//
//struct TorrentFilesView: View {
//    let torrent: Torrent
//    let manager: TorrentManager
//    
//    private func getAllFileIndices(_ node: FileNode) -> [Int] {
//        var indices: [Int] = []
//        if let fileIndex = node.fileIndex {
//            indices.append(fileIndex)
//        }
//        for child in node.children {
//            indices.append(contentsOf: getAllFileIndices(child))
//        }
//        return indices
//    }
//    
//    var body: some View {
//        VStack(spacing: 8) {
//           
//            
//            let fileTree = torrent.files.toFileTree()
//            ForEach(fileTree) { node in
//                FileNodeView(
//                    node: node,
//                    level: 0,
//                    manager: manager,
//                    torrentId: torrent.id,
//                    getAllFileIndices: getAllFileIndices
//                )
//            }
//            HStack {
//                Button(action: {
//                    Task {
//                        try? await manager.setTorrentFiles(
//                            id: torrent.id,
//                            wanted: Array(0..<torrent.files.count),
//                            unwanted: nil
//                        )
//                    }
//                }) {
//                    Text("Select All")
//                        .font(.caption)
//                }
//                .buttonStyle(.bordered)
//                
//                Button(action: {
//                    Task {
//                        try? await manager.setTorrentFiles(
//                            id: torrent.id,
//                            wanted: nil,
//                            unwanted: Array(0..<torrent.files.count)
//                        )
//                    }
//                }) {
//                    Text("Select None")
//                        .font(.caption)
//                }
//                .buttonStyle(.bordered)
//            }
//            .padding(.bottom, 4)
//            .padding(.top, 10)
//        }
//    }
//}
//
//struct FileNodeView: View {
//    let node: FileNode
//    let level: Int
//    let manager: TorrentManager
//    let torrentId: Int
//    let getAllFileIndices: (FileNode) -> [Int]
//    
//    private var torrent: Torrent? {
//        manager.torrents.first(where: { $0.id == torrentId })
//    }
//    
//    private var isWanted: Bool {
//        if node.isDirectory {
//            // A directory is "wanted" if at least one of its children is wanted
//            return !node.children.isEmpty && node.children.allSatisfy { childNode in
//                if let fileIndex = childNode.fileIndex {
//                    return torrent?.fileWantedState[fileIndex] ?? true
//                }
//                return true // Default to wanted if no fileIndex
//            }
//        } else if let fileIndex = node.fileIndex {
//            // For individual files, pull from fileStats
//            return torrent?.fileWantedState[fileIndex] ?? true
//        }
//        return true
//    }
//    
//    var body: some View {
//        VStack(alignment: .leading, spacing: 0) {
//            Button(action: {
//                Task {
//                    if node.isDirectory {
//                        let indices = getAllFileIndices(node)
//                        // If all files are wanted, make them unwanted
//                        let makeWanted = !isWanted
//                        try? await manager.setTorrentFiles(
//                            id: torrentId,
//                            wanted: makeWanted ? indices : nil,
//                            unwanted: makeWanted ? nil : indices
//                        )
//                    } else if let fileIndex = node.fileIndex {
//                        // Toggle the current state
//                        let makeWanted = !isWanted
//                        try? await manager.setTorrentFiles(
//                            id: torrentId,
//                            wanted: makeWanted ? [fileIndex] : nil,
//                            unwanted: makeWanted ? nil : [fileIndex]
//                        )
//                    }
//                }
//            }) {
//                HStack {
//                    Group {
//                        Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
//                            .foregroundColor(node.isDirectory ? .blue : .gray)
//                        
//                        Text(node.name)
//                            .lineLimit(1)
//                        
//                        Spacer()
//                        
//                        if !node.isDirectory {
//                            Text("\(Int(node.progress * 100))%")
//                                .font(.caption)
//                                .foregroundStyle(.secondary)
//                        }
//                    }
//                    .opacity(isWanted ? 1.0 : 0.4)
//                }
//                .padding(.leading, CGFloat(level * 20))
//            }
//            .buttonStyle(.plain)
//            
//            if !node.isDirectory {
//                HStack {
//                    Spacer()
//                        .frame(width: CGFloat(level * 20 + 24))
//                    ProgressView(value: node.progress)
//                        .opacity(isWanted ? 1.0 : 0.4)
//                }
//            }
//            
//            if node.isDirectory {
//                ForEach(node.children) { child in
//                    FileNodeView(
//                        node: child,
//                        level: level + 1,
//                        manager: manager,
//                        torrentId: torrentId,
//                        getAllFileIndices: getAllFileIndices
//                    )
//                }
//            }
//        }
//    }
//}
//extension Torrent {
//    var fileWantedState: [Bool] {
//        if let fileStats = dynamicFields["fileStats"]?.value as? [[String: Any]] {
//            return fileStats.compactMap { file in
//                file["wanted"] as? Bool
//            }
//        }
//        // Log if fileStats is missing
//        print("⚠️ fileStats not found or empty.")
//        return Array(repeating: true, count: files.count)
//    }
//}
