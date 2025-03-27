//
//  DeleteConfirmationView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 21/2/2025.
//

import SwiftUI

struct DeleteConfirmationView: View {
    let torrentNames: [String]
    let onCancel: () -> Void
    let onDelete: (Bool) -> Task<Void, Never>
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss
    
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("Confirm Deletion")
                .font(.headline)
                .padding(.top)
            
            // Torrent names
            VStack(alignment: .leading, spacing: 8) {
                if torrentNames.count == 1 {
                    Text("Are you sure you want to remove:")
                        .foregroundColor(.secondary)
                    Text(torrentNames[0])
                        .bold()
                } else {
                    Text("Are you sure you want to remove \(torrentNames.count) torrents?")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            
            // Buttons
            VStack(spacing: 12) {
                Button(role: .destructive) {
                    isDeleting = true
                    Task {
                        await onDelete(true).value
                        dismiss()
                    }
                } label: {
                    Label("Delete Files", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                
                Button {
                    isDeleting = true
                    Task {
                        await onDelete(false).value
                        dismiss()
                    }
                } label: {
                    Label("Remove Torrent Only", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                Button(role: .cancel) {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(isDeleting)
            .padding(.horizontal)
        }
        .padding(.bottom)
        .frame(minWidth: 300)
    }
}



// Usage example:
/*
@State private var showDeleteConfirmation = false
@State private var selectedTorrents: Set<Torrent> = []

var deleteSheet: some View {
    DeleteConfirmationView(
        torrentNames: Array(selectedTorrents).map { $0.name ?? "Unnamed Torrent" },
        onCancel: {
            selectedTorrents.removeAll()
        },
        onDelete: { deleteFiles in
            Task {
                do {
                    let ids = Array(selectedTorrents).map { $0.id }
                    try await torrentManager.deleteTorrents(
                        ids: ids,
                        deleteLocalData: deleteFiles
                    )
                    selectedTorrents.removeAll()
                } catch {
                    print("Error deleting torrents:", error)
                }
            }
        }
    )
}

// Present the sheet:
.sheet(isPresented: $showDeleteConfirmation) {
    deleteSheet
}
*/


struct TorrentDeleteSheet {
    @ObservedObject var torrentManager: TorrentManager
    let torrents: [Torrent]
    @Binding var isPresented: Bool
    
    func present() {
        isPresented = true
    }
    
    @ViewBuilder
    var sheet: some View {
        DeleteConfirmationView(
            torrentNames: torrents.map { $0.name ?? "Unnamed Torrent" },
            onCancel: {
                isPresented = false
            },
            onDelete: { deleteFiles in
                Task {
                    do {
                        let ids = torrents.map { $0.id }
                        try await torrentManager.deleteTorrents(
                            ids: ids,
                            deleteLocalData: deleteFiles
                        )
                        await MainActor.run {
                            isPresented = false
                        }
                    } catch {
                        print("Error deleting torrents:", error)
                    }
                }
                return Task { }
            }
        )
        //.presentationDetents([.medium])
    }
}

// Example usage:
/*
struct TorrentListView: View {
    @StateObject var torrentManager: TorrentManager
    @State private var showDeleteSheet = false
    
    func deleteTorrent(_ torrent: Torrent) {
        let deleteSheet = TorrentDeleteSheet(
            torrentManager: torrentManager,
            torrents: [torrent],
            isPresented: $showDeleteSheet
        )
        deleteSheet.present()
    }
    
    func deleteMultipleTorrents(_ torrents: [Torrent]) {
        let deleteSheet = TorrentDeleteSheet(
            torrentManager: torrentManager,
            torrents: torrents,
            isPresented: $showDeleteSheet
        )
        deleteSheet.present()
    }
    
    var body: some View {
        List {
            // Your torrent list items...
        }
        .sheet(isPresented: $showDeleteSheet) {
            TorrentDeleteSheet(
                torrentManager: torrentManager,
                torrents: selectedTorrents,
                isPresented: $showDeleteSheet
            ).sheet
        }
    }
}
 
 
 
 // For single torrent
 let deleteSheet = TorrentDeleteSheet(
     torrentManager: torrentManager,
     torrents: [torrent],
     isPresented: $showDeleteSheet
 )
 deleteSheet.present()

 // In your view:
 .sheet(isPresented: $showDeleteSheet) {
     deleteSheet.sheet
 }
*/
