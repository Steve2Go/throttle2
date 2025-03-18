import SwiftUI
import Combine
import mft
import KeychainAccess

// MARK: - Model
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int?
    let modificationDate: Date

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        return lhs.url == rhs.url && lhs.name == rhs.name
    }
}

// MARK: - ViewModel
class FileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var currentPath: String  // ✅ Ensure changes are detected by SwiftUI

    let basePath: String
    private var sftpConnection: MFTSftpConnection!

    init(currentPath: String, basePath: String, server: Servers?) {
        self.currentPath = currentPath
        self.basePath = basePath
        connectSFTP(server: server)
    }
    
    private func connectSFTP(server: Servers?) {
        guard let server = server else {
            print("❌ No server selected for SFTP connection")
            return
        }

        let keychain = Keychain(service: "srgim.throttle2")
        let password = keychain["sftpPassword" + server.name!]

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.sftpConnection = MFTSftpConnection(
                    hostname: server.sftpHost ?? "",
                    port: Int(server.sftpPort),
                    username: server.sftpUser ?? "",
                    password: password ?? ""
                )

                try self.sftpConnection.connect()
                try self.sftpConnection.authenticate()
                self.fetchItems()
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("SFTP Connection Error: \(error)")
                }
            }
        }
    }
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.sftpConnection.createDirectory(atPath: newFolderPath)
                
                DispatchQueue.main.async {
                    self.fetchItems() // Refresh directory after creation
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Failed to create folder: \(error)")
                }
            }
        }
    }
    func fetchItems() {
        guard !isLoading else { return }
        Task{
            DispatchQueue.global().sync(execute: {
                self.isLoading = true
            })
            
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.sftpConnection.contentsOfDirectory(atPath: self.currentPath, maxItems: 0)

                let fileItems = entries.map { entry -> FileItem in
                    let isDir = entry.isDirectory
                    let url = URL(fileURLWithPath: self.currentPath).appendingPathComponent(entry.filename)
                    
                    let fileSize = entry.isDirectory ? nil : Int(truncatingIfNeeded: entry.size)

                    return FileItem(
                        name: entry.filename,
                        url: url,
                        isDirectory: isDir,
                        size: fileSize,
                        modificationDate: entry.mtime
                    )
                }
                
                // ✅ Sort: Folders First, Then Sort by Modification Date (Newest First)
                let sortedItems = fileItems.sorted {
                    if $0.isDirectory == $1.isDirectory {
                        return $0.modificationDate > $1.modificationDate // Sort by date within each group
                    }
                    return $0.isDirectory && !$1.isDirectory // Folders first
                }

                DispatchQueue.main.async {
                    self.items = sortedItems
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("SFTP Directory Listing Error: \(error)")
                }
            }
        }
    }

    /// ✅ Navigate into a folder and refresh UI
    func navigateToFolder(_ folderName: String) {
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        
        DispatchQueue.main.async {
            self.currentPath = newPath
            self.fetchItems()
        }
    }

    /// ✅ Navigate up one directory and refresh UI
    func navigateUp() {
        guard currentPath != basePath else { return } // Prevent navigating beyond root

        // Trim the last directory from the path
        let trimmedPath = currentPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) // Remove leading/trailing slashes
            .components(separatedBy: "/") // Split into parts
            .dropLast() // Remove last folder
            .joined(separator: "/") // Rejoin

        let newPath = trimmedPath.isEmpty ? basePath : "/" + trimmedPath

        DispatchQueue.main.async {
            self.currentPath = newPath
            self.fetchItems()
        }
    }
}
// MARK: - FileBrowserView
import SwiftUI
import Combine
import mft
import KeychainAccess

// MARK: - FileBrowserView
struct FileBrowserView: View {
    @ObservedObject private var viewModel: FileBrowserViewModel
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    let onFolderSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(currentPath: String, basePath: String, server: Servers?, onFolderSelected: @escaping (String) -> Void) {
        _viewModel = ObservedObject(wrappedValue: FileBrowserViewModel(currentPath: currentPath, basePath: basePath, server: server))
        self.onFolderSelected = onFolderSelected
    }

    var body: some View {
        VStack {
#if os(macOS)
        
                HStack {
                    MacCloseButton {
                        dismiss()
                    }.padding([.top, .leading], 9).padding(.bottom, 0)
                    Spacer()
                    
                }
   
            
            //.frame(minWidth: 500, minHeight: 400)
            //.padding()
#endif
            VStack {
                List {
                    // Parent Directory Navigation
                    if viewModel.currentPath != viewModel.basePath {
                        Button(action: { viewModel.navigateUp() }) {
                            HStack {
                                Image(systemName: "arrow.up")
                                Text(".. (Up One Level)")
                            }
                        }
                    }
                    
                    // List Items
                    ForEach(viewModel.items) { item in
                        if item.isDirectory {
                            Button(action: { viewModel.navigateToFolder(item.name) }) {
                                HStack {
                                    Image("folder")
                                        .resizable()
                                        .frame(width: 60, height: 60, alignment: .center)
                                    Text(item.name)
                                }
                            }.buttonStyle(PlainButtonStyle())
                        } else {
                            HStack {
                                Image("document")
                                    .resizable()
                                    .frame(width: 60, height: 60, alignment: .center)
                                Text(item.name)
                            }
                        }
                    }
                }

                // New Folder Button (ONLY for macOS)
                #if os(macOS)
                HStack {
                    // "New Folder" Button
                    Button(action: { showNewFolderPrompt = true }) {
                   
                            Image(systemName: "folder.badge.plus")
                            Text("New Folder")
                        
                    }
                    
                    // "Select This Folder" Button
                    Button(action: {
                        onFolderSelected(viewModel.currentPath)
                        dismiss()
                    }) {
              
                            Image(systemName: "checkmark.circle.fill")
                            Text("Select This Folder")
                     
                    }
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
              
                            Image(systemName: "xmark.circle.fill")
                            Text("Cancel")
                     
                    }
                   
                }.padding(.horizontal, 20)
                #endif
            }.padding(.bottom,15)
                .navigationTitle(viewModel.currentPath.split(separator: "/").last ?? "Browse")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                    
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { showNewFolderPrompt = true }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button("Select") {
                        onFolderSelected(viewModel.currentPath)
                        dismiss()
                    }
                }
                #endif
            }
            .alert("New Folder", isPresented: $showNewFolderPrompt) {
                TextField("Folder Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { showNewFolderPrompt = false }
                Button("Create") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.createFolder(name: trimmed)
                    showNewFolderPrompt = false
                    newFolderName = ""
                }
            } message: {
                Text("Enter the name for the new folder.")
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading…")
                }
            }
        }
    }
}
//// MARK: - Servers Model (Example)
//struct Servers {
//    let name: String
//    let sftpHost: String
//    let sftpPort: Int
//    let sftpUser: String
//}
