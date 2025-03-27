//
//  RenameSheetView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/2/2025.
//


import SwiftUI

struct RenameSheetView: View {
    let selectedTorrent: Torrent?
    @Binding var renameText: String
    @Binding var showRenameAlert: Bool
    let manager: TorrentManager
    
    var body: some View {
        #if os(iOS)
        NavigationView {
            Form {
                Section("Current Name") {
                    Text(selectedTorrent?.name ?? "")
                        .foregroundStyle(.secondary)
                }
                
                Section("New Name") {
                    HStack {
                        TextField("Enter new name", text: $renameText)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                        
                        Button("Rename") {
                            performRename()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameText.isEmpty)
                    }
                }
            }
            .navigationTitle("Rename Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showRenameAlert = false
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        #else
        VStack(spacing: 12) {
            Text("Current name:")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(selectedTorrent?.name ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            
            Divider()
            
            HStack {
                TextField("New name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                
                Button("Rename") {
                    performRename()
                }
                .keyboardShortcut(.return)
                .disabled(renameText.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        #endif
    }
    
    private func performRename() {
        if let torrent = selectedTorrent {
            Task {
                do {
                    try await manager.renamePath(
                        ids: [torrent.id],
                        path: torrent.name ?? "",
                        newName: renameText
                    )
                } catch {
                    print("Error renaming torrent:", error)
                }
            }
        }
        showRenameAlert = false
    }
}