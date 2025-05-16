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
    @ObservedObject var presenting: Presenting
    @State var installerView = false
    @ObservedObject var manager: TorrentManager
    @Environment(\.openURL) private var openURL
    
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
                    }.padding([.top, .leading], 9).padding(.bottom, 0)
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
                    .toolbarBackground(.hidden)
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

                #if os(iOS)
                    Button("Clear Cache"){
                        ThumbnailManager.shared.clearCache()
                        manager.reset()
                        manager.isLoading.toggle()
                    }
                #endif
              
                
                
            } header: {
                Text("Performance")
            }
            
            //Spacer()
            Section {
                #if os(macOS)
                Text("QLVideo is used for thumbnails not normally supported on Mac.").font(.caption)
                Button("Thumbnail Settings"){
                    
                    
                    let appURL = Bundle.main.url(forResource: "QuickLookVideo", withExtension: "app")
                    // Open the app using NSWorkspace
                    NSWorkspace.shared.open(appURL!)
                }
                Text("Fuse-t and sshfs are bundled to mount your files locally in Finder.").font(.caption)
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
                Text("Mac version installs fuse-t with sshfs").font(.caption)
                Text("Mac bundle includes bundled QLVideo in it's entirety https://github.com/Marginal/QLVideo").font(.caption)
                #else
                
                Text("About").font(.headline)
                Text("iOS version installs ffmpeg on the server. https://ffmpeg.org").font(.caption)
                #endif
                
                Text("In app icons via SF Icons and https://icons8.com.").font(.caption)
                Text("App icon based on icon from https://www.iconarchive.com/").font(.caption)
                Text("Uses open source libraries VLCKit, Simpletoast and Citadel.").font(.caption)
               
                
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
//        .sheet(isPresented: $installerView){
//#if os(macOS)
//            InstallerView()
//                .frame(width: 500, height: 500)
//            
//#endif
//        }
       
        
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
