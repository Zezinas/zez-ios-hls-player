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
// MARK: PlayerWrapper  (unchanged — keep it)
// ─────────────────────────────────────────────
// fullScreenCover(item:) needs Identifiable.
// This wrapper gives AVPlayer an identity without
// modifying AVPlayer itself.

class PlayerWrapper: Identifiable {
    let id = UUID()
    let player: AVPlayer
    init(player: AVPlayer) { self.player = player }
}

// ─────────────────────────────────────────────
// MARK: PlayerManager  (new)
// ─────────────────────────────────────────────
// This is the key change. All player logic lives here
// instead of inside ContentView.
//
// @MainActor means UI updates always happen on the main
// thread, which is required for @Published properties.
//
// ObservableObject + @Published means SwiftUI will
// automatically redraw any view that reads these
// properties whenever they change.

@MainActor
class PlayerManager: ObservableObject {

    // Views watch these two properties.
    // When either changes, SwiftUI redraws the view.
    @Published var playerWrapper: PlayerWrapper?
    @Published var errorMessage: String?          // NEW: surface errors to the user

    // private(set) means other files can READ the player
    // but only PlayerManager can WRITE to it.
    private(set) var player: AVPlayer?

    func play(url: URL) {
        cleanup()   // always stop any existing playback first

        let headers = [
            "Referer": "https://www.patreon.com/",
            "Origin":  "https://www.patreon.com/"
        ]

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )

        let item        = AVPlayerItem(asset: asset)
        let newPlayer   = AVPlayer(playerItem: item)
        self.player     = newPlayer
        self.playerWrapper = PlayerWrapper(player: newPlayer)
        newPlayer.play()
    }

    func playFromClipboard() {
        // Guard gives the user a visible error instead of a silent print()
        guard let clipboardString = UIPasteboard.general.string,
              let url = URL(string: clipboardString) else {
            errorMessage = "No valid URL found in clipboard."
            return
        }
        play(url: url)
    }

    func cleanup() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player        = nil
        playerWrapper = nil
    }
}


// ─────────────────────────────────────────────
// MARK: PlayerViewController  (one fix applied)
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
        controller.player                                    = player
        controller.showsPlaybackControls                     = true
        controller.allowsPictureInPicturePlayback            = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate                                  = context.coordinator
        return controller
    }

    // FIX: guard against unnecessary re-assignments on every SwiftUI redraw.
    // The !== operator checks object identity (same instance), not equality.
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}


// ─────────────────────────────────────────────
// MARK: ContentView
// ─────────────────────────────────────────────
// Much simpler now. ContentView just shows UI and
// calls methods on PlayerManager. It doesn't own
// any player state itself.
//
// @StateObject creates ONE PlayerManager for the
// lifetime of this view. Use @StateObject when the
// view *owns* the object.

struct ContentView: View {
    @StateObject private var playerManager = PlayerManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Button {
                playerManager.playFromClipboard()
            } label: {
                Image(systemName: "film")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 90, height: 90)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // fullScreenCover watches playerManager.playerWrapper.
        // When PlayerManager sets playerWrapper, the sheet appears.
        // When the user dismisses it, cleanup() is called.
        .fullScreenCover(item: $playerManager.playerWrapper, onDismiss: {
            playerManager.cleanup()
        }) { wrapper in
            PlayerViewController(player: wrapper.player)
                .ignoresSafeArea()
        }

        // Shows an alert whenever errorMessage is set
        .alert(
            "Playback Error",
            isPresented: Binding(
                get:  { playerManager.errorMessage != nil },
                set:  { if !$0 { playerManager.errorMessage = nil } }
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
