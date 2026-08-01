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

struct PlaybackRequest {
    let sourceURL: URL
    let resumeAt: Double?
    let itemID: UUID?
    var password: String?
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
    var onPlaybackStarted: ((ResolvedStream, PlaybackRequest) -> Void)?
    var onWillDismiss: ((Double) -> Void)?
    var onVimeoPasswordRequired: ((String?) -> Void)?

    private var statusObserver: AnyCancellable?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var playbackRequestID = UUID()
    private var pendingRequest: PlaybackRequest?

    func play(
        url: URL,
        resumeAt seconds: Double? = nil,
        itemID: UUID? = nil,
        password: String? = nil
    ) {
        let request = PlaybackRequest(sourceURL: url, resumeAt: seconds, itemID: itemID, password: password)
        if itemID == nil && StreamURLResolver.isVimeoURL(url) {
            pendingRequest = request
            onVimeoPasswordRequired?(nil)
            return
        }
        beginPlayback(request)
    }

    func submitVimeoPassword(_ password: String) {
        guard var request = pendingRequest else { return }
        request.password = password.isEmpty ? nil : password
        beginPlayback(request)
    }

    func cancelPendingPlayback() {
        cleanup()
    }

    private func beginPlayback(_ request: PlaybackRequest) {
        resetPlayer()
        pendingRequest = request
        let requestID = UUID()
        playbackRequestID = requestID
        let headers = [
            "Referer": settings?.referer ?? "https://www.patreon.com/",
            "Origin": settings?.origin ?? "https://www.patreon.com/"
        ]

        Task { [weak self] in
            do {
                let stream = try await StreamURLResolver.resolve(
                    request.sourceURL,
                    headers: headers,
                    password: request.password
                )
                guard let self, self.playbackRequestID == requestID else { return }
                self.startPlayback(stream, request: request)
            } catch {
                guard let self, self.playbackRequestID == requestID else { return }
                switch error as? StreamResolutionError {
                case .vimeoPasswordRequired?, .vimeoIncorrectPassword?:
                    if request.itemID == nil {
                        self.onVimeoPasswordRequired?(error.localizedDescription)
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                default:
                    break
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func startPlayback(_ stream: ResolvedStream, request: PlaybackRequest) {
        let headers = [
            "Referer": settings?.referer ?? "https://www.patreon.com/",
            "Origin":  settings?.origin  ?? "https://www.patreon.com/"
        ]
        let asset = AVURLAsset(
            url: stream.playbackURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let item      = AVPlayerItem(asset: asset)

        let h = settings?.resolutionHeight ?? 0
        item.preferredMaximumResolution = h == 0 ? .zero : CGSize(width: 99999, height: h)
        item.preferredPeakBitRate       = settings?.peakBitRate ?? 0

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output

        let newPlayer = AVPlayer(playerItem: item)
        self.player        = newPlayer
        self.playerWrapper = PlayerWrapper(player: newPlayer)

        statusObserver = newPlayer.publisher(for: \.timeControlStatus)
            .filter { $0 == .playing }
            .first()
            .sink { [weak self] _ in
                self?.onPlaybackStarted?(stream, request)
            }

        if let t = request.resumeAt, t > 5 {
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

    func play(
        urlString: String,
        resumeAt seconds: Double? = nil,
        itemID: UUID? = nil,
        password: String? = nil
    ) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Invalid URL."
            return
        }
        play(url: url, resumeAt: seconds, itemID: itemID, password: password)
    }

    func cleanup() {
        pendingRequest = nil
        resetPlayer()
    }

    private func resetPlayer() {
        playbackRequestID = UUID()
        statusObserver?.cancel()
        statusObserver  = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player        = nil
        playerWrapper = nil
        videoOutput   = nil
    }

    func generateThumbnail(for itemID: UUID, into history: HistoryStore) {
        guard let output = videoOutput,
              let currentItem = player?.currentItem else { return }

        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else {
            currentItem.remove(output)
            videoOutput = nil
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            currentItem.remove(output)
            videoOutput = nil
            return
        }

        let image = UIImage(cgImage: cgImage)
        currentItem.remove(output)
        videoOutput = nil
        history.saveThumbnail(image, for: itemID)
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

    let resolutionOptions: [(label: String, height: Double)] = [
        ("Auto",   0),
        ("360p",   360),
        ("480p",   480),
        ("720p",   720),
        ("1080p",  1080),
        ("1440p",  1440),
        ("2160p",  2160),
    ]

    let bitrateOptions: [(label: String, bps: Double)] = [
        ("Auto",      0),
        ("250 Kbps",  250_000),
        ("500 Kbps",  500_000),
        ("750 Kbps",  750_000),
        ("1 Mbps",    1_000_000),
        ("1.5 Mbps",  1_500_000),
        ("2 Mbps",    2_000_000),
        ("3 Mbps",    3_000_000),
        ("4 Mbps",    4_000_000),
        ("6 Mbps",    6_000_000),
        ("8 Mbps",    8_000_000),
        ("10 Mbps",   10_000_000),
        ("16 Mbps",   16_000_000),
    ]

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

                Section("Quality limits") {
                    Picker("Resolution", selection: $settings.resolutionHeight) {
                        ForEach(resolutionOptions, id: \.height) { option in
                            Text(option.label).tag(option.height)
                        }
                    }
                    Picker("Bitrate", selection: $settings.peakBitRate) {
                        ForEach(bitrateOptions, id: \.bps) { option in
                            Text(option.label).tag(option.bps)
                        }
                    }
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
    @State private var showingVimeoPassword = false
    @State private var vimeoPassword = ""
    @State private var vimeoPasswordMessage: String? = nil

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
                            Button {
                                 print("Tapping item: \(item.name), resumePosition: \(String(describing: item.resumePosition)), url: \(item.url.prefix(50))")
                                 nowPlayingID = item.id
                                playerManager.play(
                                    urlString: item.url,
                                    resumeAt: item.resumePosition,
                                    itemID: item.id,
                                    password: item.password
                                )
                            } label: {
                                StreamRow(item: item)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)          // keeps your row's own styling intact
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

            playerManager.onPlaybackStarted = { stream, request in
                let existingIndex = request.itemID.flatMap { id in
                    history.items.firstIndex(where: { $0.id == id })
                } ?? history.items.firstIndex(where: { $0.url == stream.sourceURL.absoluteString })
                if let existingIndex {
                    if let password = request.password,
                       history.items[existingIndex].password != password {
                        var updatedItem = history.items[existingIndex]
                        updatedItem.password = password
                        history.update(updatedItem)
                    }
                    return
                }
                let item = StreamItem(
                    name: {
                        if let title = stream.title { return title }
                        let date = DateFormatter()
                        date.dateFormat = "yyyy-MM-dd HH:mm"
                        let suffix = stream.sourceURL.absoluteString.suffix(10)
                        return "\(date.string(from: Date())) [\(suffix)]"
                    }(),
                    creator: stream.creator ?? "unknown",
                    url: stream.sourceURL.absoluteString,
                    password: request.password
                )
                history.add(item)
                nowPlayingID = item.id
                if let thumbnailURL = stream.thumbnailURL {
                    Task {
                        await history.saveThumbnail(from: thumbnailURL, for: item.id)
                    }
                }
                playerManager.generateThumbnail(for: item.id, into: history)
            }

            playerManager.onWillDismiss = { seconds in
                guard let id = nowPlayingID else { return }
                history.updatePosition(seconds, for: id)
                playerManager.generateThumbnail(for: id, into: history)
                nowPlayingID = nil
            }

            playerManager.onVimeoPasswordRequired = { message in
                vimeoPassword = ""
                vimeoPasswordMessage = message
                showingVimeoPassword = true
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

        .alert("Vimeo Password", isPresented: $showingVimeoPassword) {
            SecureField("Password", text: $vimeoPassword)
            Button("Cancel", role: .cancel) {
                playerManager.cancelPendingPlayback()
            }
            Button("Play") {
                playerManager.submitVimeoPassword(vimeoPassword)
            }
        } message: {
            Text(vimeoPasswordMessage ?? "Enter the password for this Vimeo video.")
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
