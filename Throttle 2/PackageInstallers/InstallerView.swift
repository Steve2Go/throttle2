import SwiftUI

struct InstallerView: View {
    func installPackage() {
        // Path to the PKG file bundled with your app
        if let packagePath = Bundle.main.path(forResource: "YourPackage", ofType: "pkg") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
            process.arguments = ["-pkg", packagePath, "-target", "/"]
            
            do {
                try process.run()
                process.waitUntilExit()
                print("Installation complete")
            } catch {
                print("Failed to run installer: \(error)")
            }
        }
    }
    
    var body: some View {
        Button("Install Component") {
            installPackage()
        }
        .padding()
    }
}