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
    var settings: SettingsStore?

    private(set) var player: AVPlayer?

    // Called by ContentView once playback confirmed started
    var onPlaybackStarted: ((URL) -> Void)?
    var onWillDismiss: ((Double) -> Void)?

    private var statusObserver: AnyCancellable?
    
    func play(url: URL, resumeAt seconds: Double? = nil) {
        cleanup()
        
        let headers = [
            "Referer": settings?.referer ?? "https://www.patreon.com/",
            "Origin":  settings?.origin  ?? "https://www.patreon.com/"
        ]
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let item      = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        self.player        = newPlayer
        self.playerWrapper = PlayerWrapper(player: newPlayer)

        statusObserver = newPlayer.publisher(for: \.timeControlStatus)
            .filter { $0 == .playing }
            .first()
            .sink { [weak self] _ in
                self?.onPlaybackStarted?(url)
            }

        if let t = seconds, t > 5 {
            newPlayer.seek(to: CMTime(seconds: t, preferredTimescale: 600)) { _ in
                newPlayer.play()
            }
        } else {
            newPlayer.play()
        }
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

    func play(urlString: String, resumeAt seconds: Double? = nil) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid URL."
            return
        }
        play(url: url, resumeAt: seconds)
    }

    func cleanup() {
        statusObserver?.cancel()
        statusObserver  = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player        = nil
        playerWrapper = nil
    }
    
    func generateThumbnail(for itemID: UUID, into history: HistoryStore) {
        guard let currentItem = player?.currentItem else { return }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        currentItem.add(output)

        // Wait a few seconds for frames to be available then grab one
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            else {
                currentItem.remove(output)
                return
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                currentItem.remove(output)
                return
            }

            let image = UIImage(cgImage: cgImage)
            currentItem.remove(output)

            Task { @MainActor in
                history.saveThumbnail(image, for: itemID)
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: PlayerViewController
// ─────────────────────────────────────────────

struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    var onWillDismiss: ((Double) -> Void)?

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
        let controller = HookedPlayerViewController()
        controller.player                                          = player
        controller.showsPlaybackControls                           = true
        controller.allowsPictureInPicturePlayback                  = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate                                        = context.coordinator
        controller.onWillDisappear                                 = onWillDismiss
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        (controller as? HookedPlayerViewController)?.onWillDisappear = onWillDismiss
    }
}

class HookedPlayerViewController: AVPlayerViewController {
    var onWillDisappear: ((Double) -> Void)?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let seconds = player?.currentTime().seconds ?? 0
        onWillDisappear?(seconds)
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
// MARK: SettingsSheet
// ─────────────────────────────────────────────

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section("HTTP headers") {
                    TextField("Referer", text: $settings.referer)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Origin", text: $settings.origin)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                .overlay {
                    if let filename = item.thumbnailFilename,
                       let uiImage = UIImage(contentsOfFile:
                           FileManager.default
                               .urls(for: .documentDirectory, in: .userDomainMask)[0]
                               .appendingPathComponent(filename).path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Color(uiColor: .systemGray3))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
    
    @StateObject private var settings    = SettingsStore()
    @State private var showingSettings   = false

    @State private var urlText       = ""
    @State private var editingItem:  StreamItem? = nil
    
    @State private var nowPlayingID: UUID? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Header Recent ──
                HStack {
                    Text("RECENT")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .kerning(0.5)
                    Spacer()
                    Button("SETTINGS") {
                        showingSettings = true
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .kerning(0.5)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

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
                                    playerManager.play(urlString: item.url, resumeAt: item.resumePosition)
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
                        
                        // ── Hints row ──
                        HStack {
                            Label("swipe left to delete", systemImage: "arrow.left")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Label("swipe right to edit", systemImage: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .environment(\.layoutDirection, .rightToLeft)
                        }
                        .padding(.vertical, 0)
                        .listRowSeparator(.hidden)   // hides the divider above the hints row
                    }
                    .listStyle(.plain)
                }
                
                // ── URL bar (Safari-style, pinned top) ──
                HStack(spacing: 8) {
                    TextField("URL or paste from clipboard", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit {
                            if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                playerManager.playFromClipboard()
                            } else {
                                let submittedURL = urlText
                                playerManager.play(urlString: submittedURL)
                                urlText = ""
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button {
                        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            playerManager.playFromClipboard()
                        } else {
                            let submittedURL = urlText    // capture before clearing
                            playerManager.play(urlString: submittedURL)
                            urlText = ""
                        }
                    } label: {
                        Image(systemName: urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "list.clipboard" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .systemGray2))
                            .frame(width: 40, height: 40)
                            .background(Color(uiColor: .systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .padding(.bottom, 8)
                .background(.bar)                       // adaptive blur material
                .overlay(alignment: .top) {
                    Divider()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }

        // ── Playback ──
        .fullScreenCover(item: $playerManager.playerWrapper, onDismiss: {
            playerManager.cleanup()
        }) { wrapper in
            PlayerViewController(
                player: wrapper.player,
                onWillDismiss: playerManager.onWillDismiss
            )
            .ignoresSafeArea()
        }

        // ── Save to history on confirmed playback ──
        .onAppear {
            playerManager.settings = settings

            playerManager.onPlaybackStarted = { url in
                if let existing = history.items.first(where: { $0.url == url.absoluteString }) {
                    nowPlayingID = existing.id   // covers ALL existing items including first
                } else {
                    let item = StreamItem(
                        name: {
                            let date = DateFormatter()
                            date.dateFormat = "yyyy-MM-dd HH:mm"
                            let suffix = url.absoluteString.suffix(10)
                            return "\(date.string(from: Date())) [\(suffix)]"
                        }(),
                        creator: "unknown",
                        url: url.absoluteString
                    )
                    history.add(item)
                    nowPlayingID = item.id
                    playerManager.generateThumbnail(for: item.id, into: history)
                }
            }

            playerManager.onWillDismiss = { seconds in
                guard let id = nowPlayingID else { return }
                history.updatePosition(seconds, for: id)
                nowPlayingID = nil
            }
        }

        // ── Edit sheet ──
        .sheet(item: $editingItem) { item in
            EditItemSheet(item: item) { updated in
                history.update(updated)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(settings: settings)
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

// Enabling access to apps files via files app
// target -> Info.plist -> Key (+)
// UIFileSharingEnabled = YES                   // Application supports iTunes file sharing
// LSSupportsOpeningDocumentsInPlace = YES      // Supports opening documents in place
