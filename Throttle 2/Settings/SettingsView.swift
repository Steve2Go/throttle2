import SwiftUI

struct SettingsView: View {
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    @AppStorage("openDefaultServer") var openDefault: Bool = true
    @AppStorage("pickFiles") var pickFiles: Bool = false
    @AppStorage("pickHttp") var pickHttp: Bool = false
    @AppStorage("mountOnStart") var mountOnStart: Bool = true
    @AppStorage("unmountOnClose") var unmountOnClose: Bool = false
    @AppStorage("refreshRate") var refreshRate: Int = 5
    @AppStorage("externalPlayerPrefix") var externalPlayerPrefix: String = "vlc://"
    @AppStorage("externalPlayerAll") var externalPlayerAll: Bool = false
    @AppStorage("showThumbs") var showThumbs: Bool = false
    @AppStorage("preferVLC") var preferVLC: Bool = false
    @AppStorage("usePlaylist") var usePlaylist: Bool = false
    @AppStorage("waitPlaylist") var waitPlaylist: Int = 5
    @AppStorage("primaryFile") var primaryFiles: Bool = false
    @AppStorage("deleteOnSuccess") var deleteOnSuccess: Bool = true
    @AppStorage("qlVideo") var qlVideo: Bool = false
    @AppStorage("isAbout") var isAbout = false
    @AppStorage("mountOnLogin") var mountOnLogin = false
    @AppStorage("thumbsLocal") var thumbsLocal = false
    @AppStorage("finderBrowser") var finderBrowser: Bool = false
    @AppStorage("useInternalBrowser") var useInternalBrowser: Bool = false
    // COMMENTED OUT DUE TO MPV HARDENED RUNTIME ISSUES - ALWAYS USING DEFAULT PLAYER
    // @AppStorage("useDefaultMediaPlayer") var useDefaultMediaPlayer: Bool = false
    @AppStorage("preferredVideoPlayer") var preferredVideoPlayer: String = "system"
    @ObservedObject var presenting: Presenting
    @State var installerView = false
    @ObservedObject var manager: TorrentManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    
    func isVLCInstalled() -> Bool {
            #if os(iOS)
            // Use a simple vlc:// URL to test if VLC is installed
            guard let vlcUrl = URL(string: "vlc://") else { return false }
            return UIApplication.shared.canOpenURL(vlcUrl)
            #else
            // For macOS, you might want to check differently or always return true
            return true
            #endif
        }
    var body: some View {
        HStack (alignment: .top){
#if os(macOS)
            ZStack (alignment: .top, content: {
                content
                HStack {
                    MacCloseButton {
                        presenting.activeSheet = nil
                    }.padding([.top, .leading], 12).padding(.bottom, 0)
                    Spacer()
                }
            })
            
            //.frame(minWidth: 500, minHeight: 400)
            //.padding()
#else
            NavigationStack {
                content
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.large)
                    //.toolbarBackground(.hidden)
            }
            .toolbar{
                ToolbarItem(placement: .automatic) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            
#endif
        }
    }
    
    private var content: some View {
        
        Form  {
            
            Section {
                settingRow(
                    title: "Sync servers with iCloud",
                    description: "Synchronize server settings across devices. Restart Required.",
                    control: Toggle("", isOn: $useCloudKit)
                )
                settingRow(
                    title: openDefault ? "Opening Default Server" : "Opening Last Used Server",
                    description: "Automatically connect to server on launch",
                    control: Toggle("", isOn: $openDefault)
                )
                settingRow(
                    title: "Delete Torrents",
                    description: ".torrent deletion after a sucessful upload",
                    control: Toggle("", isOn: $deleteOnSuccess)
                )
                settingRow(
                    title: "Show Thumbnails in List",
                    description: "Show thumbnails in Torrent List when available",
                    control: Toggle("", isOn: $showThumbs)
                )

            } header: {
                Text("General")
            } footer: {
                Text("These settings affect the general behavior of the app")
            }.padding(.top, 5)
            
            Section {
                settingRow(
                    title: "Refresh Rate",
                    description: "How often the content is updated",
                    control: HStack {
                        Text("\(refreshRate) seconds")
                            .frame(minWidth: 80, alignment: .trailing)
                        Stepper("", value: $refreshRate, in: 1...60)
                    }
                )
                
                #if os(macOS)
                settingRow(
                    title: "Local Thumbnail Generation",
                    description: "Generate thumbnails from finder, even when using SSH/SFTP",
                    control: Toggle("", isOn: $thumbsLocal)
                ) .onChange(of: thumbsLocal){
                    manager.reset()
                }
                
                settingRow(
                    title: "Use Internal Browser",
                    description: "Use built-in browser for browsing remote files instead of Finder",
                    control: Toggle("", isOn: $useInternalBrowser)
                )
                
                if useInternalBrowser {
                    // COMMENTED OUT DUE TO MPV HARDENED RUNTIME ISSUES - ALWAYS USING DEFAULT PLAYER
                    /*
                    settingRow(
                        title: "Use Default Media Player",
                        description: "Use system default media player instead of mpv for videos and audio",
                        control: Toggle("", isOn: $useDefaultMediaPlayer)
                    )
                    */
                }
                #endif
               
                    Button("Clear Cache"){
                        #if os(macOS)
                        ThumbnailManager.shared.clearCache()
                        #endif
                        ThumbnailManagerRemote.shared.clearCache()
                        manager.reset()
                        manager.isLoading.toggle()
                    }
            
              
                
                
            } header: {
                Text("Performance")
            }
            
            //Spacer()
            Section {
                #if os(macOS)
//                Text("QLVideo is used for thumbnails not normally supported on Mac.").font(.caption)
//                Button("Thumbnail Settings"){
//                    let qlvideoURL = URL(fileURLWithPath: "/Applications/QLVideo.app")
//                    if FileManager.default.fileExists(atPath: qlvideoURL.path) {
//                        NSWorkspace.shared.open(qlvideoURL)
//                    } else {
//                        // If QLVideo is not installed, show the installer
//                        installerView.toggle()
//                    }
//                }
                Text("Fuse-t and sshfs are installed to mount your files locally in Finder.").font(.caption)
                Button("Reinstall File Integration Tools"){
                    installerView.toggle()
                }
                
               
//                Button("Install Fuse File System") {
//                    installerView.toggle()
//                }
//                settingRow(
//                    title: "Mount servers on launch",
//                    description: "Mount remote files when Throttle opens",
//                    control: Toggle("", isOn: $mountOnLogin)
//                )
                settingRow(
                    title: "Mount Servers on login",
                    description: "Mount remote files when you log into your Computer",
                    control: Toggle("", isOn: $mountOnLogin)
                )
//                settingRow(
//                    title: "Unmount Server Files on close",
//                    description: "Unmount the fuse file system when the app closes",
//                    control: Toggle("", isOn: $mountOnOpen)
//                )
                Text("About").font(.headline)
                Text("Uses fuse-t with sshfs for file access: https://www.fuse-t.org").font(.caption)
                Text("We recommend QLVideo for Thumbnails: https://github.com/Marginal/QLVideo").font(.caption)
                #else
                
                Text("About").font(.headline)
                
                #endif
                Text("Installs ffmpeg on the server. https://ffmpeg.org").font(.caption)
                Text("In app icons via SF Icons and https://icons8.com.").font(.caption)
                Text("App icon based on icon from https://www.iconarchive.com/").font(.caption)
                Text("Uses open source libraries VLCKit, Simpletoast and Citadel.").font(.caption)
                Text("Intermodal is used for torrrent creation https://github.com/casey/intermodal").font(.caption)
               
                
                Text("Licenced under the GPL v2 or later").font(.caption)
            }header: {
                Text("Tools & About")
            }
            
        }
       
        .formStyle(.grouped)
        .padding(.top, 0)
        .defaultScrollAnchor(isAbout ? .bottom : .top)
        .onDisappear{
            isAbout = false
        }
        #if os(macOS)
        .sheet(isPresented: $installerView){
            InstallerView()
                .frame(width: 500, height: 500)
        }
        #endif
       
        
    }
    
    private func settingRow<Control: View>(
        title: String,
        description: String,
        control: Control
    ) -> some View {
        #if os(macOS)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            control
                .labelsHidden()
        }
        .padding(.vertical, 4)
        #else
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                control
                    .labelsHidden()
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.gray)
        }



        #endif
    }
}

//#Preview("iOS") {
//    SettingsView()
//}
//
//#Preview("macOS") {
//    SettingsView()
//}
