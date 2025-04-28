import SwiftUI
import UniformTypeIdentifiers
import Citadel
//import mft
import NIO

protocol SFTPUploadHandler {
    // Get the connection manager for SFTP operations
    func getConnectionManager() -> SFTPConnectionManager?
    
    var currentPath: String { get }
    func refreshItems()
}

// Update SFTPUploadManager to work with both connection types
class SFTPUploadManager: ObservableObject {
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var currentUploadFileName: String = ""
    @Published var error: String?
    
    private var uploadHandler: SFTPUploadHandler
    private var totalFiles = 0
    private var processedFiles = 0
    private var uploadTask: Task<Void, Error>?
    
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
        
        // Check if we can use the ConnectionManager
        if let connectionManager = uploadHandler.getConnectionManager() {
            uploadWithCitadel(localURL: localURL, connectionManager: connectionManager)
        }
    }
    
    private func uploadWithCitadel(localURL: URL, connectionManager: SFTPConnectionManager) {
        uploadTask = Task {
            do {
                defer { localURL.stopAccessingSecurityScopedResource() }
                
                let destinationPath = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                
                // Upload the file with progress monitoring
                try await connectionManager.uploadFile(
                    localURL: localURL,
                    remotePath: destinationPath
                ) { progress in
                    // Update progress on the main thread
                    Task { @MainActor in
                        self.uploadProgress = progress
                    }
                    // Check if the upload was cancelled
                    return !Task.isCancelled
                }
                
                await MainActor.run {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
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
        
        // Check if we can use the ConnectionManager
        if let connectionManager = uploadHandler.getConnectionManager() {
            uploadFolderWithCitadel(localURL: localURL, connectionManager: connectionManager)
        }
    }
    
    private func uploadFolderWithCitadel(localURL: URL, connectionManager: SFTPConnectionManager) {
        uploadTask = Task {
            do {
                defer {
                    localURL.stopAccessingSecurityScopedResource()
                    print("📂 Stopped accessing security-scoped resource for main folder")
                }
                
                let fileManager = FileManager.default
                
                // Create the base remote directory first
                let destinationBase = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                print("📂 Creating base remote directory: \(destinationBase)")
                
                // Create the base directory
                try await connectionManager.createDirectory(atPath: destinationBase)
                
                // Get all contents
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
                
                guard let enumerator = directoryEnumerator else {
                    throw NSError(domain: "SFTPUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create enumerator"])
                }
                
                print("📂 Starting enumeration of contents")
                var files: [URL] = []
                var directories: [String] = []
                let basePath = localURL.path
                
                // First pass: identify all files and directories
                for case let fileURL as URL in enumerator {
                    // Check for cancellation
                    try Task.checkCancellation()
                    
                    print("📂 Found item: \(fileURL)")
                
                    let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                    let isDirectory = resourceValues.isDirectory ?? false
                    
                    // Get relative path from the base folder
                    var relativePath = String(fileURL.path.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                    
                    let destinationPath = "\(destinationBase)/\(relativePath)"
                        .replacingOccurrences(of: "//", with: "/")
                    
                    print("📂 Processing: \(relativePath) -> \(destinationPath)")
                    print("📂 Is directory: \(isDirectory)")
                    
                    if isDirectory {
                        directories.append(destinationPath)
                    } else {
                        files.append(fileURL)
                    }
                }
                
                // Create all directories first
                print("📂 Creating \(directories.count) directories")
                for path in directories {
                    try Task.checkCancellation()
                    print("📂 Creating directory: \(path)")
                    try await connectionManager.createDirectory(atPath: path)
                }
                
                // Then upload all files
                print("📂 Uploading \(files.count) files")
                self.totalFiles = files.count
                self.processedFiles = 0
                
                for (index, fileURL) in files.enumerated() {
                    try Task.checkCancellation()
                    
                    print("📂 Starting upload of file: \(fileURL)")
                    
                    var relativePath = String(fileURL.path.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                    
                    let destinationPath = "\(destinationBase)/\(relativePath)"
                        .replacingOccurrences(of: "//", with: "/")
                    
                    print("📂 Uploading to: \(destinationPath)")
                    
                    // Get file size for progress reporting
                    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 1 // Avoid division by zero
                    
                    // Upload the file with progress monitoring
                    try await connectionManager.uploadFile(
                        localURL: fileURL,
                        remotePath: destinationPath
                    ) { fileProgress in
                        // Calculate overall progress (file progress + already completed files)
                        let overallProgress = (Double(index) + fileProgress) / Double(files.count)
                        
                        Task { @MainActor in
                            self.uploadProgress = overallProgress
                        }
                        
                        // Check if the upload was cancelled
                        return !Task.isCancelled
                    }
                    
                    self.processedFiles += 1
                    let progress = Double(self.processedFiles) / Double(self.totalFiles)
                    print("📂 Progress: \(progress * 100)%")
                    
                    await MainActor.run {
                        self.uploadProgress = progress
                    }
                }
                
                await MainActor.run {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
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
        // Cancel the task if using Citadel
        uploadTask?.cancel()
        
        // Regardless of which method was used, update the UI
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
extension SFTPFileBrowserViewModel: SFTPUploadHandler {
    func getConnectionManager() -> SFTPConnectionManager? {
        return connectionManager
    }
    
    func refreshItems() {
        self.fetchItems()
    }
}
#endif
