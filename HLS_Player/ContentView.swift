//
//  ContentView.swift
//  HLS_Player
//
//  Created by Zezinas on 2026-04-12.
//

import SwiftUI
import AVKit
import Combine

// ─────────────────────────────────────────────
// MARK: PlayerWrapper
// ─────────────────────────────────────────────

class PlayerWrapper: Identifiable {
    let id = UUID()
    let player: AVPlayer
    init(player: AVPlayer) { self.player = player }
}

// ─────────────────────────────────────────────
// MARK: PlayerManager
// ─────────────────────────────────────────────

@MainActor
class PlayerManager: ObservableObject {
    @Published var playerWrapper: PlayerWrapper?
    @Published var errorMessage: String?

    private(set) var player: AVPlayer?

    // Called by ContentView once playback confirmed started
    var onPlaybackStarted: ((URL) -> Void)?

    private var statusObserver: AnyCancellable?

    func play(url: URL) {
        cleanup()

        let headers = [
            "Referer": "https://www.patreon.com/",
            "Origin":  "https://www.patreon.com/"
        ]
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let item      = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        self.player        = newPlayer
        self.playerWrapper = PlayerWrapper(player: newPlayer)

        // Observe status — only fire onPlaybackStarted once playing is confirmed
        statusObserver = newPlayer.publisher(for: \.timeControlStatus)
            .filter { $0 == .playing }
            .first()
            .sink { [weak self] _ in
                self?.onPlaybackStarted?(url)
            }

        newPlayer.play()
    }

    func playFromClipboard() {
        guard let clipboardString = UIPasteboard.general.string,
              let url = URL(string: clipboardString.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            errorMessage = "No valid URL found in clipboard."
            return
        }
        play(url: url)
    }

    func play(urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid URL."
            return
        }
        play(url: url)
    }

    func cleanup() {
        statusObserver?.cancel()
        statusObserver  = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player        = nil
        playerWrapper = nil
    }
}

// ─────────────────────────────────────────────
// MARK: PlayerViewController
// ─────────────────────────────────────────────

struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: PlayerViewController
        init(_ parent: PlayerViewController) { self.parent = parent }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player                                          = player
        controller.showsPlaybackControls                           = true
        controller.allowsPictureInPicturePlayback                  = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate                                        = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

// ─────────────────────────────────────────────
// MARK: EditItemSheet
// ─────────────────────────────────────────────

struct EditItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: StreamItem
    var onSave: (StreamItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Video details") {
                    TextField("Name", text: $item.name)
                    TextField("Creator", text: $item.creator)
                }
                Section("URL") {
                    TextField("https://...", text: $item.url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.name.isEmpty || item.url.isEmpty)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: StreamRow
// ─────────────────────────────────────────────

struct StreamRow: View {
    let item: StreamItem

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .systemGray5))
                .frame(width: 72, height: 48)
                .overlay(
                    Image(systemName: "video.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color(uiColor: .systemGray3))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.creator)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.relativeTime)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// ─────────────────────────────────────────────
// MARK: ContentView
// ─────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var playerManager = PlayerManager()
    @StateObject private var history       = HistoryStore()

    @State private var urlText       = ""
    @State private var editingItem:  StreamItem? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── URL bar (Safari-style, pinned top) ──
                HStack(spacing: 8) {
                    TextField("URL or paste from clipboard", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button {
                        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            playerManager.playFromClipboard()
                        } else {
                            playerManager.play(urlString: urlText)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)                       // adaptive blur material
                .overlay(alignment: .bottom) {
                    Divider()
                }

                // ── History list ──
                if history.items.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                        Text("Play a stream to see it here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(history.items) { item in
                            StreamRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playerManager.play(urlString: item.url)
                                }
                                // Swipe left → delete
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        if let index = history.items.firstIndex(where: { $0.id == item.id }) {
                                            history.delete(at: IndexSet(integer: index))
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                // Swipe right → edit
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        editingItem = item
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("HLS Player")
            .navigationBarTitleDisplayMode(.inline)
        }

        // ── Playback ──
        .fullScreenCover(item: $playerManager.playerWrapper, onDismiss: {
            playerManager.cleanup()
        }) { wrapper in
            PlayerViewController(player: wrapper.player)
                .ignoresSafeArea()
        }

        // ── Save to history on confirmed playback ──
        .onAppear {
            playerManager.onPlaybackStarted = { url in
                let item = StreamItem(
                    name:    urlText.isEmpty ? "Untitled stream" : "Stream",
                    creator: "unknown",
                    url:     url.absoluteString
                )
                history.add(item)
            }
        }

        // ── Edit sheet ──
        .sheet(item: $editingItem) { item in
            EditItemSheet(item: item) { updated in
                history.update(updated)
            }
        }

        // ── Error alert ──
        .alert(
            "Playback Error",
            isPresented: Binding(
                get: { playerManager.errorMessage != nil },
                set: { if !$0 { playerManager.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { playerManager.errorMessage = nil }
        } message: {
            Text(playerManager.errorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
}

// In Xcode:
// Target → Signing & Capabilities → + Capability → Background Modes
// Audio, AirPlay, and Picture in Picture
