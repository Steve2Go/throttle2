import SwiftUI
import UniformTypeIdentifiers
import Citadel
import NIO

// Updated protocol to use SSHConnection instead of SFTPConnectionManager
protocol SFTPUploadHandler {
    // Get the server entity for SSH operations
    func getServer() -> ServerEntity?
    
    var currentPath: String { get }
    func refreshItems()
}

// Update SFTPUploadManager to work with SSHConnection
class SFTPUploadManager: ObservableObject {
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var currentUploadFileName: String = ""
    @Published var error: String?
    
    private var uploadHandler: SFTPUploadHandler
    private var totalFiles = 0
    private var processedFiles = 0
    private var uploadTask: Task<Void, Error>?
    private var sshConnection: SSHConnection?
    
    init(uploadHandler: SFTPUploadHandler) {
        self.uploadHandler = uploadHandler
    }
    
    func uploadFile(from localURL: URL) {
        guard localURL.startAccessingSecurityScopedResource() else {
            error = "Failed to access file"
            return
        }
        
        isUploading = true
        currentUploadFileName = localURL.lastPathComponent
        uploadProgress = 0
        
        // Create a new SSH connection using the server from the handler
        if let server = uploadHandler.getServer() {
            uploadWithSSH(localURL: localURL, server: server)
        } else {
            Task { @MainActor in
                self.error = "Server configuration not found"
                self.isUploading = false
                localURL.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    private func uploadWithSSH(localURL: URL, server: ServerEntity) {
        uploadTask = Task {
            do {
                defer { localURL.stopAccessingSecurityScopedResource() }
                let destinationPath = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                // Use the helper for robust cleanup
                try await SSHConnection.withConnection(server: server) { connection in
                    self.sshConnection = connection
                    try await connection.uploadFile(
                        localURL: localURL,
                        remotePath: destinationPath
                    ) { progress in
                        Task { @MainActor in
                            self.uploadProgress = progress
                        }
                    }
                }
                self.sshConnection = nil
                await MainActor.run {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
                self.sshConnection = nil
                if error is CancellationError {
                    print("Upload cancelled by user")
                } else {
                    print("Upload error: \(error)")
                    await MainActor.run {
                        self.error = error.localizedDescription
                        self.isUploading = false
                    }
                }
            }
        }
    }
    
    func uploadFolder(from localURL: URL) {
        print("📂 Starting folder upload for: \(localURL)")
        
        guard localURL.startAccessingSecurityScopedResource() else {
            error = "Failed to access folder"
            print("❌ Failed to access security-scoped resource for folder")
            return
        }
        
        isUploading = true
        currentUploadFileName = localURL.lastPathComponent
        uploadProgress = 0
        
        // Collect all URLs synchronously before entering async context
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let directoryEnumerator = fileManager.enumerator(
            at: localURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                print("❌ Error enumerating \(url): \(error)")
                return true // Continue enumeration
            }
        )
        var enumeratedURLs: [URL] = []
        if let enumerator = directoryEnumerator {
            for case let fileURL as URL in enumerator {
                enumeratedURLs.append(fileURL)
            }
        }
        
        // Create a new SSH connection using the server from the handler
        if let server = uploadHandler.getServer() {
            uploadFolderWithSSH(localURL: localURL, server: server, enumeratedURLs: enumeratedURLs)
        } else {
            Task { @MainActor in
                self.error = "Server configuration not found"
                self.isUploading = false
                localURL.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    // Add enumeratedURLs as a parameter
    private func uploadFolderWithSSH(localURL: URL, server: ServerEntity, enumeratedURLs: [URL]) {
        uploadTask = Task {
            do {
                defer {
                    localURL.stopAccessingSecurityScopedResource()
                    print("📂 Stopped accessing security-scoped resource for main folder")
                }
                let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
                let destinationBase = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                print("📂 Creating base remote directory: \(destinationBase)")
                // Use the helper for robust cleanup
                try await SSHConnection.withConnection(server: server) { connection in
                    self.sshConnection = connection
                    try await connection.createDirectory(path: destinationBase)
                    print("📂 Starting enumeration of contents")
                    var files: [URL] = []
                    var directories: [String] = []
                    let basePath = localURL.path
                    for fileURL in enumeratedURLs {
                        try Task.checkCancellation()
                        print("📂 Found item: \(fileURL)")
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        let isDirectory = resourceValues.isDirectory ?? false
                        var relativePath = String(fileURL.path.dropFirst(basePath.count))
                        if relativePath.hasPrefix("/") {
                            relativePath = String(relativePath.dropFirst())
                        }
                        let destinationPath = "\(destinationBase)/\(relativePath)"
                            .replacingOccurrences(of: "//", with: "/")
                        print("📂 Processing: \(relativePath) -> \(destinationPath)")
                        if isDirectory {
                            try await connection.createDirectory(path: destinationPath)
                            directories.append(destinationPath)
                        } else {
                            try await connection.uploadFile(
                                localURL: fileURL,
                                remotePath: destinationPath
                            ) { progress in
                                // Optionally update progress here
                            }
                            files.append(fileURL)
                        }
                    }
                }
                self.sshConnection = nil
                await MainActor.run {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
                self.sshConnection = nil
                if error is CancellationError {
                    print("Upload cancelled by user")
                } else {
                    print("Upload error: \(error)")
                    await MainActor.run {
                        self.error = error.localizedDescription
                        self.isUploading = false
                    }
                }
            }
        }
    }
    
    func cancelUpload() {
        // Cancel the task
        uploadTask?.cancel()
        
        // Also disconnect the SSH connection if one exists
        if let connection = sshConnection {
            Task {
                await connection.disconnect()
                self.sshConnection = nil
            }
        }
        
        // Update the UI
        Task { @MainActor in
            self.isUploading = false
            self.error = "Upload cancelled"
        }
    }
}

// MARK: - SFTPUploadView with Cancel Button
struct SFTPUploadView: View {
    @StateObject var uploadManager: SFTPUploadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if uploadManager.isUploading {
                    VStack {
                        Text("Uploading \(uploadManager.currentUploadFileName)")
                            .font(.headline)
                        ProgressView(value: uploadManager.uploadProgress)
                            .progressViewStyle(.linear)
                        Text("\(Int(uploadManager.uploadProgress * 100))%")
                            .padding(.vertical, 4)
                        
                        // Add cancel button
                        Button("Cancel", role: .destructive) {
                            uploadManager.cancelUpload()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    Button(action: {
                        showFilePicker = true
                    }){
                        VStack{
                            Image(systemName: "arrow.up.document")
                                .resizable()
                                .frame(width: 40, height: 50)
                            Text("Choose Files or Folders")
                        }.padding(20)
                    }
                    .buttonStyle(.bordered)
                    
                    if let error = uploadManager.error {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .padding()
            .frame(minWidth: 300, minHeight: 150)
            .navigationTitle("Upload")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item, .folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.hasDirectoryPath {
                        uploadManager.uploadFolder(from: url)
                    } else {
                        uploadManager.uploadFile(from: url)
                    }
                case .failure(let error):
                    uploadManager.error = error.localizedDescription
                }
            }
        }
    }
}

#if os(iOS)
// Update the SFTPFileBrowserViewModel conformance to the new protocol
extension SFTPFileBrowserViewModel: SFTPUploadHandler {
    func getServer() -> ServerEntity? {
        return server
    }
    
    func refreshItems() {
        self.fetchItems()
    }
}
#endif
