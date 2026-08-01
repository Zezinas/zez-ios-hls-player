//
//  URLResolver.swift
//  HLS_Player
//

import Foundation

struct ResolvedStream: Sendable {
    let sourceURL: URL
    let playbackURL: URL
    let title: String?
    let thumbnailURL: URL?
}

enum StreamURLResolver {
    static func resolve(_ sourceURL: URL) async throws -> ResolvedStream {
        guard let streamableID = try streamableID(from: sourceURL) else {
            return ResolvedStream(
                sourceURL: sourceURL,
                playbackURL: sourceURL,
                title: nil,
                thumbnailURL: nil
            )
        }

        let endpoint = URL(string: "https://api.streamable.com/videos/\(streamableID)")!
        let (data, response) = try await URLSession.shared.data(from: endpoint)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw StreamResolutionError.streamableUnavailable
        }

        let streamable = try JSONDecoder().decode(StreamableResponse.self, from: data)
        guard let file = ["mp4-high", "mp4", "mp4-mobile"]
            .compactMap({ streamable.files[$0] })
            .first(where: { $0.isAvailable && $0.playbackURL != nil }),
              let playbackURL = file.playbackURL
        else {
            throw StreamResolutionError.streamableUnavailable
        }

        return ResolvedStream(
            sourceURL: sourceURL,
            playbackURL: playbackURL,
            title: streamable.title?.nonEmpty,
            thumbnailURL: streamable.thumbnailURL
        )
    }

    private static func streamableID(from url: URL) throws -> String? {
        guard let host = url.host?.lowercased(),
              host == "streamable.com" || host == "www.streamable.com"
        else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        let id: String?
        switch components.count {
        case 1:
            id = components[0]
        case 2 where components[0] == "e" || components[0] == "o":
            id = components[1]
        default:
            id = nil
        }

        guard let id, !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            throw StreamResolutionError.invalidStreamableURL
        }
        return id
    }
}

private struct StreamableResponse: Decodable {
    let title: String?
    let files: [String: StreamableFile]
    let thumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case title
        case files
        case thumbnailURL = "thumbnail_url"
    }
}

private struct StreamableFile: Decodable {
    let status: Int?
    let url: String?

    var isAvailable: Bool {
        status == nil || status == 2
    }

    var playbackURL: URL? {
        guard let url else { return nil }
        if url.hasPrefix("//") {
            return URL(string: "https:\(url)")
        }
        return URL(string: url)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

enum StreamResolutionError: LocalizedError {
    case invalidStreamableURL
    case streamableUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidStreamableURL:
            return "This Streamable link does not contain a valid video ID."
        case .streamableUnavailable:
            return "This Streamable video is unavailable or has no playable MP4 file."
        }
    }
}
