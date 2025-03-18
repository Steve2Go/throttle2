import SwiftUI
#if os(macOS)
import AppKit
    #endif

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MutateTorrentView: View {
    @ObservedObject var torrentManager: TorrentManager
    let torrent: Torrent
    @Binding var showMoveSheet: Bool
    @Binding var showRenameAlert: Bool
    @State private var moveLocation = ""
    @State private var showFileBrowser = false
    @State var server: Servers?

    var content: some View {
        #if os(iOS)
        NavigationView {
            Form {
                Section("New Location") {
                    HStack {
                        TextField("Enter new location", text: $moveLocation)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        if ServerManager.shared.selectedServer?.fsBrowse == true {
                            Button {
                                showFileBrowser = true
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Move Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        Task {
                            do {
                                try await torrentManager.moveTorrents(
                                    ids: [torrent.id],
                                    to: moveLocation,
                                    move: true
                                )
                                showMoveSheet = false
                            } catch {
                                print("Error moving torrent:", error)
                            }
                        }
                    }.disabled(moveLocation.isEmpty)
                }
            }
        }
        #else
        VStack(spacing: 20) {
            Text("Move Torrent").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("New Location:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("", text: $moveLocation)
                        .textFieldStyle(.roundedBorder)
                    
                    if ServerManager.shared.selectedServer?.fsBrowse == true {
                        Button { openFilePicker() } label: {
                            Image(systemName: "folder")
                        }
                    } else if ServerManager.shared.selectedServer?.httpBrowse == true {
                        Button { showFileBrowser = true } label: {
                            Image(systemName: "folder")
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { showMoveSheet = false }

                Button("Move") {
                    Task {
                        do {
                            try await torrentManager.moveTorrents(
                                ids: [torrent.id],
                                to: moveLocation,
                                move: true
                            )
                            showMoveSheet = false
                        } catch {
                            print("Error moving torrent:", error)
                        }
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(moveLocation.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
        #endif
    }

    #if os(macOS)
    func openFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = URL(string: "files://" + serverPath_to_local(moveLocation))
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            moveLocation = local_to_serverPath(selectedURL.absoluteString.removingPercentEncoding ?? "")
        }
    }
    #endif

    var body: some View {
        content
            .sheet(isPresented: $showFileBrowser) {
                NavigationView {
                    let server = ServerManager.shared.selectedServer
                    FileBrowserView(
                        currentPath: moveLocation,
                        basePath: server?.pathFilesystem ?? "",
                        server: server,
                        onFolderSelected: { folder in
                            moveLocation = folder
                            showFileBrowser = false
                        }
                    )
                }
            }
            .onAppear {
                Task {
                    if let downloadDir = try? await torrentManager.getDownloadDirectory() {
                        await MainActor.run {
                            moveLocation = downloadDir
                        }
                    }
                }
            }
    }
}
struct MutateTorrent {
    @ObservedObject var torrentManager: TorrentManager
    let torrent: Torrent
    @Binding var showMoveSheet: Bool
    @Binding var showRenameAlert: Bool
    @State var newPath = ""
    var server: Servers?
    
    func move() {
        showMoveSheet = true
    }
    
    func rename() {
        if let name = torrent.name {
            newPath = name
            showRenameAlert = true
        }
    }
    
    var moveSheet: some View {
        MutateTorrentView(
            torrentManager: torrentManager,
            torrent: torrent,
            showMoveSheet: $showMoveSheet,
            showRenameAlert: $showRenameAlert
        )
    }
}
