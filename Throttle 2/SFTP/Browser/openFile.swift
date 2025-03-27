//
//  FileItem.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/3/2025.
//
#if os(iOS)
import SwiftUI

// MARK: - File Browser View Model Extension
extension SFTPFileBrowserViewModel {
    func openFile(item: FileItem, server: ServerEntity) {
            guard !item.isDirectory else {
                navigateToFolder(item.name)
                return
            }
            
            let fileType = FileType.determine(from: item.url)
            
            switch fileType {
            case .video:
                @AppStorage("preferVLC") var preferVLC: Bool = false
             if preferVLC && isVLCInstalled() {
                   openVideoInVLC(item: item, server: server)
              } else {
                  openVideo(item: item, server: server)
               }
            case .image:
                openImageBrowser(item)
            case .other:
                downloadFile(item)
            }
        }
}
#endif
