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
    
    // Keep both connection methods for gradual transition
    //var sftpConnection: MFTSftpConnection!
    private var connectionManager: SFTPConnectionManager

    init(currentPath: String, basePath: String, server: ServerEntity?) {
        self.currentPath = currentPath
        self.basePath = basePath
        
        // Initialize the connection manager
        self.connectionManager = SFTPConnectionManager(server: server)
        // The connection manager initializes the MFT connection, so we can reference it
        //self.sftpConnection = connectionManager.mftConnection
        
        // Connect to the server
        connectToServer()
    }
    
    private func connectToServer() {
        Task {
            do {
                try await connectionManager.connect()
                await fetchItems()
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("SFTP Connection Error: \(error)")
                }
            }
        }
    }
    
    func createFolder(name: String) {
        let newFolderPath = "\(currentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
        
        Task {
            do {
                try await connectionManager.createDirectory(atPath: newFolderPath)
                await fetchItems() // Refresh directory after creation
            } catch {
                await MainActor.run {
                    print("❌ Failed to create folder: \(error)")
                }
            }
        }
    }
    
    func fetchItems() async {
        // Skip if already loading
        guard !isLoading else { return }
        
        await MainActor.run {
            self.isLoading = true
        }
        
        do {
            // Get directory contents using the connection manager
            let fileItems = try await connectionManager.contentsOfDirectory(atPath: currentPath)
            
            // Calculate "up one" display text
            let upOneValue = NSString(string: NSString(string: currentPath).deletingLastPathComponent).lastPathComponent
            
            // Sort items: Folders first, then by modification date (newest first)
            let sortedItems = fileItems.sorted {
                if $0.isDirectory == $1.isDirectory {
                    return $0.modificationDate > $1.modificationDate // Sort by date within each group
                }
                return $0.isDirectory && !$1.isDirectory // Folders first
            }
            
            await MainActor.run {
                self.upOne = upOneValue
                self.items = sortedItems
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                print("SFTP Directory Listing Error: \(error)")
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
}


// MARK: - FileBrowserView
import SwiftUI
import Combine
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

// upload conformance
extension FileBrowserViewModel: SFTPUploadHandler {
    
    // Implementing the required methods
    func getConnectionManager() -> SFTPConnectionManager? {
        return connectionManager
    }
    
    func refreshItems() {
        Task {
            await self.fetchItems()
        }
    }
}
