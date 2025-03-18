import SwiftUI
import CoreData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AddTorrentView: View {
    
    @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Servers.name, ascending: true)],
            animation: .default)
        private var servers: FetchedResults<Servers>
    @ObservedObject var store: Store
    @ObservedObject var manager: TorrentManager
//    @ObservedObject var store.selection: Servers
    @State var presenting: Presenting
    
    @State private var isShowingFilePicker = false
    @State private var downloadDir: String = ""
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var fileBrowser = false
    @Binding var activeSheet: ActiveSheet?
    
    var body: some View {
        Text("test")
    }
//        NavigationStack {
//            #if os(macOS)
//            VStack(alignment: .leading, spacing: 15) {
//                Text("Add a Download")
//                    .font(.title2)
//                    .padding(.bottom, 10)
//
//                
//
//                HStack {
//                    Text("Torrent")
//                    if store.selectedFile == nil {
//                        TextField("Magnet Link or File", text: $store.magnetLink)
//                            .textFieldStyle(.roundedBorder)
//                    } else {
//                        Button {
//                            store.selectedFile = nil
//                        } label: {
//                            HStack {
//                                Text(store.selectedFile!.lastPathComponent)
//                                Image(systemName: "xmark.circle.fill")
//                            }
//                        }
//                        .buttonStyle(.plain)
//                    }
//
//                    Button {
//                        isShowingFilePicker = true
//                    } label: {
//                        Image(systemName: "folder")
//                    }
//                    .buttonStyle(.borderless)
//                }
//
//                if let pathServer = store.selection?.pathServer {
//                    HStack {
//                        Text("Download Directory:")
//                        HStack {
//                            TextField("Download Directory", text: $downloadDir)
//                                .textFieldStyle(.roundedBorder)
//                                .onAppear {
//                                    if downloadDir.isEmpty {
//                                        Task {
//                                            await updateDownloadDirectory()
//                                        }
//                                    }
//                                }
//                            if store.selection?.sftpBrowse == true  {
//                                Button {
//                                    
//                                    fileBrowser = true
//                                } label: {
//                                    Image(systemName: "folder")
//                                }.buttonStyle(.plain)
//                            }
//                            else if store.selection?.fsBrowse == true {
//                                Button {
//                                    //openPanel()
//                                    openFilePicker()
//                                } label: {
//                                    Image(systemName: "folder")
//                                }.buttonStyle(.plain)
//                            }
//                            
//                        }
//                    }
//                }
//                HStack {
//                    //Text("Server:")
//                    Picker("Server", selection: $store.selection) {
//                        ForEach(servers) { server in
//                            Text(server.name).tag(server)
//                        }
//                    }
//                    .onChange(of: store.selection) { _ in
//                        Task {
//                            await updateDownloadDirectory()
//                        }
//                    }
//                    .pickerStyle(MenuPickerStyle())
//                }
//
//                HStack {
//                    Spacer()
//                    Button("Cancel") {
//                        activeSheet = nil
//                    }
//                    Button("Add") {
//                        Task { @MainActor in
//                            await addTorrent()
//                        }
//                    }
//                    .disabled((store.magnetLink.isEmpty && store.selectedFile == nil) || isLoading)
//                }
//                .padding(.top, 10)
//
//                if isLoading {
//                    ProgressView()
//                        .progressViewStyle(CircularProgressViewStyle())
//                        .padding(.top, 5)
//                }
//            }
//            .padding()
//            .frame(minWidth: 400, maxWidth: 600, minHeight: 300)
//            #else
//            Form {
//                
//
//                Section("Add Torrent") {
//                    HStack {
//                        if store.selectedFile == nil {
//                            TextField("Magnet Link or File", text: $store.magnetLink)
//                                .textFieldStyle(.roundedBorder)
//                        } else {
//                            Button {
//                                store.selectedFile = nil
//                            } label: {
//                                HStack {
//                                    Text(store.selectedFile!.lastPathComponent)
//                                    Image(systemName: "xmark")
//                                }
//                            }
//                        }
//
//                        Spacer()
//
//                        Button {
//                            isShowingFilePicker = true
//                        } label: {
//                            Image(systemName: "folder")
//                        }
//                        .buttonStyle(.plain)
//                    }
//
//                    if let pathServer = store.selection?.pathServer {
//                        HStack {
//                            TextField("Download Directory", text: $downloadDir)
//                                .textFieldStyle(.roundedBorder)
//                                .onAppear {
//                                    if downloadDir.isEmpty {
//                                        Task {
//                                            await updateDownloadDirectory()
//                                            //print("DLDIR is " + serverPath_to_url(downloadDir, server: store.selection))
//                                        }
//                                    }
//                                }
//                            if ServerManager.shared.selectedServer?.sftpBrowse == true  {
//                                Button {
//                                    fileBrowser = true
//                                } label: {
//                                    Image(systemName: "folder")
//                                }
//                                .buttonStyle(.plain)
//                            }
//                        }
//                        
//                    }
//                }
//                
//                Section("Server") {
//                    Picker("Server", selection: $store.selection) {
//                        ForEach(servers) { server in
//                            Text(server.name).tag(server)
//                        }
//                    }
//                    .onChange(of: store.selection) { _ in
//                        store.selection = store.selection
//                        Task {
//                            //print("DLDIR changed to " + serverPath_to_url(downloadDir, server: store.selection))
//                            await updateDownloadDirectory()
//                        }
//                    }
//                }
//
//                Section {
//                    HStack {
//                        Button("Cancel") {
//                            activeSheet = nil
//                        }
//
//                        Spacer()
//
//                        if isLoading {
//                            ProgressView()
//                        }
//
//                        Button("Add") {
//                            Task { @MainActor in
//                                await addTorrent()
//                            }
//                        }
//                        .disabled((store.magnetLink.isEmpty && store.selectedFile == nil) || isLoading)
//                    }
//                }
//            }
//            .navigationTitle("Add a Download")
//            .scrollContentBackground(.hidden)
//            .background(Color(uiColor: .systemGroupedBackground))
//            #endif
//        }
////        .fileImporter(
////            isPresented: $isShowingFilePicker,
////            allowedContentTypes: [UTType(filenameExtension: "torrent")!, .data],
////            allowsMultipleSelection: false
////        ) { result in
////            switch result {
////            case .success(let files):
////                if let fileURL = files.first {
////                    if fileURL.startAccessingSecurityScopedResource() {
////                        store.selectedFile = fileURL
////                        store.magnetLink = ""
////                    } else {
////                        self.error = NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Permission denied to access the file."])
////                        showError = true
////                    }
////                }
////            case .failure(let error):
////                self.error = error
////                print("File Import Error: \(error.localizedDescription)")
////                showError = true
////            }
////        }
//
//        .sheet(isPresented: $fileBrowser, content: {
//            //Text(url_to_url(store.selection.pathHttp!, server: store.selection))
////#if os(iOS)
////            NavigationView {
////                FileBrowserView(
////                    currentPath: downloadDir,
////                    basePath: store.selection.pathServer ?? "", // Use `pathFilesystem` instead of `pathHttp`
////                    server: store.selection,  // Pass the selected server dynamically
////                    onFolderSelected: { folderPath in
////                        downloadDir = folderPath
////                        fileBrowser = false
////                    }
////                )
////            }
////#else
////            VStack {
////                FileBrowserView(
////                    currentPath: downloadDir,
////                    basePath: store.selection?.pathServer ?? "", // Use `pathFilesystem` instead of `pathHttp`
////                    server: store.selection,  // Pass the selected server dynamically
////                    onFolderSelected: { folderPath in
////                        downloadDir = folderPath
////                        fileBrowser = false
////                    }
////                )
////            }.frame(width: 600, height: 600)
////        
////            
////            #endif
////    MacFileBrowserView(currentURL: URL( string: serverPath_to_url(downloadDir))!, baseURL: URL( string: url_to_url(store.selection.pathHttp!))!,
////                                      onFolderSelected: { folder in
////                                      downloadDir = url_to_serverPath(folder.absoluteString)
////                                          fileBrowser = false
////                                      }
////                                  )
////
////        .frame( width: 800, height: 500)
//
//  //  #endif
//        }
//              
//        )
//
//        .alert("Error", isPresented: $showError, presenting: error) { _ in
//            Button("OK") { }
//        } message: { error in
//            Text(error.localizedDescription)
//        }
    }

    
//    private func updateDownloadDirectory() async {
//        do {
//            try await Task.sleep(for: .milliseconds(500))
//            if let directory = try? await manager.getDownloadDirectory() {
//                await MainActor.run {
//                    downloadDir = directory
//                }
//            }
//        } catch {
//            // Handle sleep error if needed
//        }
//   
//    }
    
    #if os(macOS)
    func openFilePicker() {
//            let openPanel = NSOpenPanel()
//            // Set the initial directory (e.g., Desktop directory)
//            openPanel.directoryURL = URL ( string: "files://" + serverPath_to_local(downloadDir))  // initial location
//            openPanel.allowsMultipleSelection = false
//            openPanel.canChooseDirectories = true
//            openPanel.canChooseFiles = false
//            
//            if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
//                print("Selected file: \(selectedURL)")
//                // Handle the selected file URL as needed
//                downloadDir = local_to_serverPath(selectedURL.absoluteString.removingPercentEncoding ?? "")
//            }
        }
#endif
    
    @MainActor
    func addTorrent() async {
//        isLoading = true
//        
//        do {
//            let file = store.selectedFile
//            let dir = downloadDir.isEmpty ? store.selection?.pathServer : downloadDir
//            
//            var magnetLinkParam: String? = nil
//            if !store.magnetLink.isEmpty {
//                magnetLinkParam = store.magnetLink
//            }
//            
//            let response = try await manager.addTorrent(
//                fileURL: file,
//                magnetLink: magnetLinkParam,
//                downloadDir: dir
//            )
//            
//            if response.result != "success" {
//                throw NSError(domain: "", code: -1,
//                    userInfo: [NSLocalizedDescriptionKey: "Failed to add torrent"])
//            } else {
//                activeSheet = nil
//                isLoading = false
//            }
//            
//        } catch {
//            isLoading = false
//            self.error = error
//            showError = true
//        }
//    }
}
