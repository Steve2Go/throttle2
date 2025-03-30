import SwiftUI
import UniformTypeIdentifiers
import mft

protocol SFTPUploadHandler {
    func getConnection() -> MFTSftpConnection
    var currentPath: String { get }
    func refreshItems()
}

class SFTPUploadManager: ObservableObject {
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var currentUploadFileName: String = ""
    @Published var error: String?
    
    private var uploadHandler: SFTPUploadHandler
    private var totalFiles = 0
    private var processedFiles = 0
    
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
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { localURL.stopAccessingSecurityScopedResource() }
            
            guard let self = self else { return }
            
            do {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
                let inputStream = InputStream(url: localURL)!
                let destinationPath = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                
                try self.uploadHandler.getConnection().write(
                    stream: inputStream,
                    toFileAtPath: destinationPath,
                    append: false
                ) { bytesUploaded in
                    DispatchQueue.main.async {
                        self.uploadProgress = Double(bytesUploaded) / Double(fileSize)
                    }
                    return true
                }
                
                DispatchQueue.main.async {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isUploading = false
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
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                localURL.stopAccessingSecurityScopedResource()
                print("📂 Stopped accessing security-scoped resource for main folder")
            }
            
            guard let self = self else { return }
            
            do {
                let fileManager = FileManager.default
                
                // Create the base remote directory first
                let destinationBase = "\(self.uploadHandler.currentPath)/\(localURL.lastPathComponent)"
                    .replacingOccurrences(of: "//", with: "/")
                print("📂 Creating base remote directory: \(destinationBase)")
                try self.uploadHandler.getConnection().createDirectory(atPath: destinationBase)
                
                // Get all contents using the newer API
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
                    print("📂 Creating directory: \(path)")
                    try self.uploadHandler.getConnection().createDirectory(atPath: path)
                }
                
                // Then upload all files
                print("📂 Uploading \(files.count) files")
                self.totalFiles = files.count
                self.processedFiles = 0
                
                for fileURL in files {
                    print("📂 Starting upload of file: \(fileURL)")
                    
                    var relativePath = String(fileURL.path.dropFirst(basePath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                    
                    let destinationPath = "\(destinationBase)/\(relativePath)"
                        .replacingOccurrences(of: "//", with: "/")
                    
                    print("📂 Uploading to: \(destinationPath)")
                    guard let inputStream = InputStream(url: fileURL) else {
                        print("❌ Failed to create input stream for: \(fileURL)")
                        continue
                    }
                    
                    try self.uploadHandler.getConnection().write(
                        stream: inputStream,
                        toFileAtPath: destinationPath,
                        append: false
                    ) { bytesWritten in
                        print("📂 Wrote \(bytesWritten) bytes")
                        return true
                    }
                    
                    self.processedFiles += 1
                    let progress = Double(self.processedFiles) / Double(self.totalFiles)
                    print("📂 Progress: \(progress * 100)%")
                    DispatchQueue.main.async {
                        self.uploadProgress = progress
                    }
                }
                
                DispatchQueue.main.async {
                    self.uploadHandler.refreshItems()
                    self.isUploading = false
                    self.uploadProgress = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isUploading = false
                }
            }
        }
    }
}

struct SFTPUploadView: View {
    @StateObject var uploadManager: SFTPUploadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    
    var body: some View {
        NavigationStack{
        VStack(spacing: 20) {
            if uploadManager.isUploading {
                VStack {
                    Text("Uploading \(uploadManager.currentUploadFileName)")
                        .font(.headline)
                    ProgressView(value: uploadManager.uploadProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int(uploadManager.uploadProgress * 100))%")
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
            }.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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

// MARK: - View Model Extensions
extension FileBrowserViewModel: SFTPUploadHandler {
    func getConnection() -> MFTSftpConnection {
        return sftpConnection
    }
    
    func refreshItems() {
        Task{
            await self.fetchItems()
        }
    }
}

#if os(iOS)
extension SFTPFileBrowserViewModel: SFTPUploadHandler {
    func getConnection() -> MFTSftpConnection {
        return sftpConnection
    }
    
    func refreshItems() {
        self.fetchItems()
    }
}
#endif
