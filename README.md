# zez-ios-hls-player

A minimal iOS HLS / URL stream player. Paste a URL, hit play.

> Made this as my first iOS app for myself, rubbing 2 braincells together and using an LLM — use it, fork it, do whatever you want with it, just don't expect any support.

## Features
- Play HLS streams directly from clipboard URL
- Play Streamable page links directly
- Play public, unlisted, and password-protected Vimeo links directly
- Browse History and imported playlists
- Create empty playlists from the app
- (PiP) Picture in picture support
- Background playback with media controls
- Resume playback at last known timestamp
- Recent streams history
- Edit and delete recent items
- Auto-generated thumbnails
- App data accessible via Files app (.json item list and .jpg thumbnails)
- Custom Referer and Origin HTTP headers setting
- Preferred maximum resolution setting
- Preferred maximum bitrate setting

## Vimeo Passwords
- Vimeo passwords entered in the app are saved in plaintext with that video in `history.json`.

## Playlists
- `history.json` is the built-in History playlist.
- Copy playlist files to the app's `Documents/playlists/` folder through Files.
- Use the `+` button to create sequential empty playlist files such as `playlist_001.json`.
- A playlist name is derived from its filename: `anime-reactions.json` appears as `Anime Reactions`.
- Rename or delete a playlist in the Files app by managing its `.json` file in the app's `playlists` folder.
- Do not rename or delete `history.json`; it is managed by the app.
- New thumbnails are stored in the app's `Documents/images/` folder.
- Each playlist file is a JSON array using the same full item format as `history.json`:

```json
[
  {
    "id": "A40E5B54-C4D6-4E41-A131-CCB5354D314C",
    "name": "Episode 1",
    "creator": "Creator",
    "url": "https://vimeo.com/123456",
    "password": "optional-password",
    "addedAt": 0,
    "thumbnailFilename": "images/A40E5B54-C4D6-4E41-A131-CCB5354D314C.jpg",
    "resumePosition": null
  }
]
```

- `addedAt` is measured in seconds since January 1, 2001.
- Editing or deleting a playlist item in the app rewrites that playlist JSON file.
- URLs played from the home-screen input are saved to History after playback starts.
- URLs played from inside a playlist are saved to that playlist's JSON file after playback starts.

## Known Issues
- Sometimes clicking recent list items does nothing, holding 1-2 seconds works — you will see UI feedback that it's registering

## Sideloading
The IPA in releases is unsigned. Install via SideStore, AltStore, or compile it yourself with Xcode.

## Requirements
- iOS 17.6+
- SideStore / AltStore or Xcode for installation
