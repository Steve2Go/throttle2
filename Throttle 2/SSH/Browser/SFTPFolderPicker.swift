import SwiftUI
import Combine
import KeychainAccess
import Citadel
import NIO

// MARK: - ViewModel
class FileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var currentPath: String  // ✅ Ensure changes are detected by SwiftUI
    @Published var upOne = ""
    let basePath: String
    
    // Store the server entity for SSH connections
    let server: ServerEntity?
    
    // Use SSH connection instead of connection manager
    private var sshConnection: SSHConnection?

    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        self.server = server
        
        // Connect to the server
        connectToServer()
    }
    
    private func connectToServer() {
        Task {
            do {
                // Create and connect a new SSH connection
                if let server = server {
                    let connection = SSHConnection(server: server)
                    try await connection.connect()
                    
                    // Store the connection for future use
                    self.sshConnection = connection
                    
                    // Fetch initial directory listing
                    await fetchItems()
                } else {
                    throw NSError(domain: "FileBrowser", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Server configuration missing"])
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("SSH Connection Error: \(error)")
                }
            }
        }
    }
    
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
        
        Task {
            do {
                // Use the existing connection or create a new one if needed
                let connection = try await getOrCreateConnection()
                
                // Create the directory using SSH
                try await connection.createDirectory(path: newFolderPath)
                
                // Refresh directory listing
                await fetchItems()
            } catch {
                await MainActor.run {
                    print("❌ Failed to create folder: \(error)")
                }
            }
        }
    }
    
    // Helper to get or create an SSH connection
    private func getOrCreateConnection() async throws -> SSHConnection {
        // Create a new connection if we don't have one
        if sshConnection == nil {
            guard let server = server else {
                throw NSError(domain: "FileBrowser", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Server configuration missing"])
            }
            
            // Create and connect a new SSH connection
            let connection = SSHConnection(server: server)
            try await connection.connect()
            
            // Store for future use
            self.sshConnection = connection
        }
        
        // Return the existing or newly created connection
        guard let connection = sshConnection else {
            throw NSError(domain: "FileBrowser", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create SSH connection"])
        }
        
        return connection
    }
    
    func fetchItems() async {
        // Skip if already loading
        guard !isLoading else { return }
        
        await MainActor.run {
            self.isLoading = true
        }
        
        do {
            // Get or create a connection
            let connection = try await getOrCreateConnection()
            
            // Get directory contents using the SSH connection
            // The connection.listDirectory returns SFTPPathComponent, so we need to convert to FileItem
            let sftpComponents = try await connection.listDirectory(path: currentPath)
            
            // Convert SFTPPathComponent to FileItem objects
            let fileItems = sftpComponents.compactMap { component -> FileItem? in
                // Skip "." and ".." entries
                if component.filename == "." || component.filename == ".." {
                    return nil
                }
                
                // Create a URL for the item
                let url = URL(fileURLWithPath: "\(currentPath)/\(component.filename)")
                                .standardized
                
                // Check if it's a directory based on the attributes
                let isDirectory = component.attributes.permissions != nil &&
                                 (component.attributes.permissions! & 0x4000) != 0
                
                // Get the size and modification date
                let size = isDirectory ? nil : Int(component.attributes.size ?? 0)
                let modDate = component.attributes.accessModificationTime?.modificationTime ?? Date()
                
                return FileItem(
                    name: component.filename,
                    url: url,
                    isDirectory: isDirectory,
                    size: size,
                    modificationDate: modDate
                )
            }
            
            // Calculate "up one" display text
            let upOneValue = NSString(string: NSString(string: currentPath).deletingLastPathComponent).lastPathComponent
            
            // Sort items with explicit type annotations to avoid compiler inference issues
            let sortedItems = fileItems.sorted { (a: FileItem, b: FileItem) -> Bool in
                if a.isDirectory == b.isDirectory {
                    return a.modificationDate > b.modificationDate // Sort by date within each group
                }
                return a.isDirectory && !b.isDirectory // Folders first
            }
            
            await MainActor.run {
                self.upOne = upOneValue
                self.items = sortedItems
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                print("SSH Directory Listing Error: \(error)")
            }
        }
    }
    
    /// ✅ Navigate into a folder and refresh UI
    func navigateToFolder(_ folderName: String) {
        let newPath = "\(currentPath)/\(folderName)".replacingOccurrences(of: "//", with: "/")
        
        Task { @MainActor in
            self.currentPath = newPath
            await fetchItems()
        }
    }
    
    /// ✅ Navigate up one directory and refresh UI
    func navigateUp() {
        guard currentPath != basePath else { return } // Prevent navigating beyond root
        
        // Trim the last directory from the path
        let trimmedPath = currentPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .dropLast()
            .joined(separator: "/")
        let newPath = trimmedPath.isEmpty ? basePath : "/" + trimmedPath
        
        Task { @MainActor in
            self.currentPath = newPath
            await fetchItems()
        }
    }
    
    // Cleanup resources when view model is deallocated
    deinit {
        // Clean up SSH connection
        if let connection = sshConnection {
            Task {
                await connection.disconnect()
            }
        }
    }
}


// MARK: - FileBrowserView
struct FileBrowserView: View {
    @StateObject private var viewModel: FileBrowserViewModel
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var selectFiles: Bool
    @State private var showUploadView = false
    @State private var currentPath: String = ""
       
    let onFolderSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(currentPath: String, basePath: String, server: ServerEntity?, onFolderSelected: @escaping (String) -> Void, selectFiles: Bool = false) {
        _viewModel = StateObject(wrappedValue: FileBrowserViewModel(currentPath: currentPath, basePath: basePath, server: server))
        self.onFolderSelected = onFolderSelected
        _selectFiles = State(initialValue: selectFiles)
        _currentPath = State(initialValue: currentPath)
    }
       
    private var uploadManager: SFTPUploadManager {
        SFTPUploadManager(uploadHandler: viewModel)
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
                // Parent Directory Navigation
                if viewModel.currentPath != viewModel.basePath {
                    #if os(macOS)
                    HStack {
                        Button(action: { viewModel.navigateUp() }) {
                            HStack {
                                Image(systemName: "arrow.up")
                                //Text(".. (Up One Level)")
                                Text( viewModel.upOne == "/" ? "Top Level" : viewModel.upOne.capitalized )
                            }
                        }.padding(.leading,20)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                }
                ScrollView {
                    LazyVStack {
                    
                        
                        
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                HStack {
                                    Image("document")
                                        .resizable()
                                        .frame(width: 60, height: 60, alignment: .center)
                                    HStack{
                                    Text(item.name)
                                        Spacer()
                                        if selectFiles == true {
                                            Button{
                                                onFolderSelected(viewModel.currentPath + "/" + item.name)
                                                dismiss()
                                            } label:{
#if os(iOS)
                                                Image(systemName: "checkmark.circle.fill")
                                                #endif
                                                Text("Select File")
                                            }
                                        }
                                }
                                    
                                }
                                
                            }
                            Divider()
                        }.padding(.horizontal,20)
                    }
                }
                
                #if os(iOS)
                
                    .toolbar{
                        if viewModel.currentPath != viewModel.basePath {
                            ToolbarItem(placement: .topBarLeading){
                            Button {
                                viewModel.navigateUp()
                            } label: {
                                Image(systemName: "chevron.backward")
                                Text(viewModel.upOne == "/" ? "Top Level" : viewModel.upOne.capitalized)
                            }
                        }
                    }
                }
#endif
                // New Folder Button (ONLY for macOS)
                //#if os(macOS)
                Divider()
                    .padding(0)
                HStack {
                    // "New Folder" Button
                    Button(action: { showNewFolderPrompt = true }) {
                        VStack{
#if os(iOS)
                            Image(systemName: "folder.badge.plus")
                               // .resizable()
                                .frame(width: 20, height: 20)
                            #endif
                            Text("New Folder")
                        }
                        
                    }
                
#if os(iOS)
                    Spacer()
                    #endif
                    Button {
                        showUploadView.toggle()
                    } label: {
                        VStack{
#if os(iOS)
                            Image(systemName: "arrow.up.document")
                                //.resizable()
                                .frame(width: 20, height: 20)
                            #endif
                            Text("Upload")
                        }
                    }
                    
#if os(iOS)
                    Spacer()
                    #endif
                    // "Select This Folder" Button
                    Button(action: {
                        onFolderSelected(viewModel.currentPath)
                        dismiss()
                    }) {
                        VStack{
#if os(iOS)
                            Image(systemName: "checkmark.circle.fill")
                             //   .resizable()
                                .frame(width: 20, height: 20)
#endif
                            Text("Select Folder")
                        }
                    }
                    #if os(macOS)
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
                        VStack{
//                            Image(systemName: "xmark.circle.fill")
//                                //.resizable()
//                                .frame(width: 20, height: 20)
                            Text("Cancel")
                        }
                    }
#endif
                }
                
                .padding(.horizontal, 20)
                
                #if os(iOS)
                .padding(.top,15)
                #endif
            }.padding(.bottom,15)
                .navigationTitle(NSString(string: viewModel.currentPath).lastPathComponent)
//            .toolbar {
//                #if os(iOS)
//                ToolbarItemGroup() {
//                    Button(action: { showNewFolderPrompt = true }) {
//                        Label("New Folder", systemImage: "folder.badge.plus")
//                    }
//                    Button("Select") {
//                        onFolderSelected(viewModel.currentPath)
//                        dismiss()
//                    }
//                }
//                #endif
//            }
            .sheet(isPresented: $showUploadView) {
                        SFTPUploadView(uploadManager: uploadManager)
#if os(iOS)
.presentationDetents([.medium])
#else
.frame(width: 300, height: 200)
.padding(0)
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

// Update the upload handler conformance to use the updated protocol
extension FileBrowserViewModel: SFTPUploadHandler {
    // Instead of providing a connection manager, provide the server entity
    func getServer() -> ServerEntity? {
        return server
    }
    
    func refreshItems() {
        Task {
            await self.fetchItems()
        }
    }
}
