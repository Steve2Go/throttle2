import SwiftUI

struct FileNodeRow: View {
    let node: FileNode
    let level: Int
    @Binding var expandedFolders: Set<String>
    @Binding var unwantedFiles: Set<Int>
    let isFileWanted: (Int) -> Bool
    let getAllFileIndices: (FileNode) -> [Int]
    let toggleNode: (FileNode) -> Void
    let folderStatus: (FileNode) -> (icon: String, color: Color)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if node.isDirectory {
                HStack {
                    Button(action: { toggleExpand() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    Button(action: { toggleNode(node) }) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.blue)
                        Image(systemName: folderStatus(node).icon)
                            .foregroundColor(folderStatus(node).color)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.leading, CGFloat(level * 20))
                if isExpanded {
                    ForEach(node.children) { child in
                        FileNodeRow(
                            node: child,
                            level: level + 1,
                            expandedFolders: $expandedFolders,
                            unwantedFiles: $unwantedFiles,
                            isFileWanted: isFileWanted,
                            getAllFileIndices: getAllFileIndices,
                            toggleNode: toggleNode,
                            folderStatus: folderStatus
                        )
                    }
                }
            } else {
                HStack {
                    Button(action: { toggleNode(node) }) {
                        Image(systemName: isFileWanted(node.fileIndex ?? -1) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isFileWanted(node.fileIndex ?? -1) ? .green : .red)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical,3)
                    Spacer()
                }
                .padding(.leading, CGFloat(level * 20 + 20))
            }
        }
    }
    private var isExpanded: Bool {
        expandedFolders.contains(node.id)
    }
    private func toggleExpand() {
        if isExpanded {
            expandedFolders.remove(node.id)
        } else {
            expandedFolders.insert(node.id)
        }
    }
}

struct FileSelectionView: View {
    let fileTree: [FileNode]
    let initialUnwanted: Set<Int>
    let onSave: (Set<Int>) -> Void
    let onCancel: () -> Void

    @State private var expandedFolders: Set<String> = []
    @State private var unwantedFiles: Set<Int> = []
    @State private var initialized = false

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

    private func toggleNode(_ node: FileNode) {
        if node.isDirectory {
            let indices = getAllFileIndices(node)
            let allWanted = indices.allSatisfy { isFileWanted($0) }
            if allWanted {
                unwantedFiles.formUnion(indices)
            } else {
                unwantedFiles.subtract(indices)
            }
        } else if let fileIndex = node.fileIndex {
            if isFileWanted(fileIndex) {
                unwantedFiles.insert(fileIndex)
            } else {
                unwantedFiles.remove(fileIndex)
            }
        }
    }

    private func folderStatus(_ node: FileNode) -> (icon: String, color: Color) {
        let indices = getAllFileIndices(node)
        let allOn = indices.allSatisfy { isFileWanted($0) }
        let allOff = indices.allSatisfy { !isFileWanted($0) }
        if allOn {
            return ("checkmark.circle.fill", .green)
        } else if allOff {
            return ("xmark.circle.fill", .red)
        } else {
            return ("minus.circle.fill", .blue)
        }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(fileTree) { node in
                    FileNodeRow(
                        node: node,
                        level: 0,
                        expandedFolders: $expandedFolders,
                        unwantedFiles: $unwantedFiles,
                        isFileWanted: isFileWanted,
                        getAllFileIndices: getAllFileIndices,
                        toggleNode: toggleNode,
                        folderStatus: folderStatus
                    )
                    
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(unwantedFiles)
                    }
                }
            }
        }
        .onAppear {
            if !initialized {
                unwantedFiles = initialUnwanted
                expandedFolders = []
                initialized = true
            }
        }
    }
}
