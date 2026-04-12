# zez-ios-hls-player

A minimal iOS HLS / URL stream player. Paste a URL, hit play.

> Made this as my first iOS app for myself, rubbing 2 braincells together and using an LLM — use it, fork it, do whatever you want with it, just don't expect any support.

## Features
- Play HLS streams directly from clipboard URL
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

## Known Issues
- Sometimes clicking recent list items does nothing, holding 1-2 seconds works — you will see UI feedback that it's registering

## Sideloading
The IPA in releases is unsigned. Install via SideStore, AltStore, or compile it yourself with Xcode.

## Requirements
- iOS 17.6+
- SideStore / AltStore or Xcode for installation
