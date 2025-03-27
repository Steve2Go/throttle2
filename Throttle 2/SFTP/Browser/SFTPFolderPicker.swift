import SwiftUI
import Combine
import mft
import KeychainAccess




// MARK: - ViewModel
class FileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var currentPath: String  // ✅ Ensure changes are detected by SwiftUI
    @Published var upOne = ""
    let basePath: String
    var sftpConnection: MFTSftpConnection!

    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        connectSFTP(server: server)
    }
    
    private func connectSFTP(server: ServerEntity?) {
        guard let server = server else {
            print("❌ No server selected for SFTP connection")
            return
        }
        
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if server.sftpUsesKey {
                    // Retrieve the key from the keychain and use it for authentication
                    let key = keychain["sftpKey" + (server.name ?? "")] ?? ""
                    let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
                    self.sftpConnection = MFTSftpConnection(
                        hostname: server.sftpHost ?? "",
                        port: Int(server.sftpPort),
                        username: server.sftpUser ?? "",
                        prvKey: key,
                        passphrase: password// Using key-based initializer
                    )
                } else {
                    // Use password-based authentication
                    let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
                    self.sftpConnection = MFTSftpConnection(
                        hostname: server.sftpHost ?? "",
                        port: Int(server.sftpPort),
                        username: server.sftpUser ?? "",
                        password: password
                    )
                }
                
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
       
            DispatchQueue.main.async {
                self.isLoading = true
            }
            
  
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try self.sftpConnection.contentsOfDirectory(atPath: self.currentPath, maxItems: 0)
                
                DispatchQueue.main.async {
                    self.upOne = NSString( string:  NSString( string: self.currentPath ).deletingLastPathComponent ).lastPathComponent
                }
                
                
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
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .dropLast()
            .joined(separator: "/")
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
                                            Button("Select File", systemImage: "checkmark.circle.fill"){
                                                onFolderSelected(viewModel.currentPath + "/" + item.name)
                                                dismiss()
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
                            Image(systemName: "folder.badge.plus")
                               // .resizable()
                                .frame(width: 20, height: 20)
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
                            Image(systemName: "arrow.up.document")
                                //.resizable()
                                .frame(width: 20, height: 20)
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
                            Image(systemName: "checkmark.circle.fill")
                             //   .resizable()
                                .frame(width: 20, height: 20)
                            Text("Select Folder")
                        }
                    }
                    #if os(macOS)
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
                        VStack{
                            Image(systemName: "xmark.circle.fill")
                                //.resizable()
                                .frame(width: 20, height: 20)
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

