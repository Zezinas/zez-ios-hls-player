//
//  URLResolver.swift
//  HLS_Player
//

import Foundation

struct ResolvedStream: Sendable {
    let sourceURL: URL
    let playbackURL: URL
    let title: String?
    let creator: String?
    let thumbnailURL: URL?
}

enum StreamURLResolver {
    static func isVimeoURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return host == "vimeo.com" || host == "www.vimeo.com" || host == "player.vimeo.com"
    }

    static func resolve(
        _ sourceURL: URL,
        headers: [String: String] = [:],
        password: String? = nil
    ) async throws -> ResolvedStream {
        if let streamableID = try streamableID(from: sourceURL) {
            return try await resolveStreamable(sourceURL, id: streamableID)
        }

        if let vimeoLink = try vimeoLink(from: sourceURL) {
            return try await resolveVimeo(vimeoLink, headers: headers, password: password)
        }

        return ResolvedStream(
            sourceURL: sourceURL,
            playbackURL: sourceURL,
            title: nil,
            creator: nil,
            thumbnailURL: nil
        )
    }

    private static func resolveStreamable(_ sourceURL: URL, id: String) async throws -> ResolvedStream {
        let endpoint = URL(string: "https://api.streamable.com/videos/\(id)")!
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
            creator: nil,
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

    private static func vimeoLink(from url: URL) throws -> VimeoLink? {
        guard let host = url.host?.lowercased() else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        if host == "player.vimeo.com" {
            guard pathComponents.count >= 2, pathComponents[0] == "video" else {
                throw StreamResolutionError.invalidVimeoURL
            }
            return try VimeoLink(
                id: pathComponents[1],
                unlistedHash: queryItems?.first(where: { $0.name == "h" })?.value,
                sourceURL: url
            )
        }

        guard host == "vimeo.com" || host == "www.vimeo.com" else { return nil }
        guard let idIndex = pathComponents.firstIndex(where: { $0.allSatisfy(\.isNumber) }) else {
            throw StreamResolutionError.invalidVimeoURL
        }

        let unlistedHash = pathComponents.dropFirst(idIndex + 1).first(where: isVimeoHash)
            ?? queryItems?.first(where: { $0.name == "h" })?.value
        return try VimeoLink(id: pathComponents[idIndex], unlistedHash: unlistedHash, sourceURL: url)
    }

    private nonisolated static func isVimeoHash(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isHexDigit }
    }

    private static func resolveVimeo(
        _ link: VimeoLink,
        headers: [String: String],
        password: String?
    ) async throws -> ResolvedStream {
        let configURL = link.playerURL(appending: "config")
        let initialResponse = try await requestVimeoConfig(at: configURL, headers: headers)

        if let stream = resolvedVimeoStream(from: initialResponse.data, sourceURL: link.sourceURL) {
            return stream
        }

        guard let password, !password.isEmpty else {
            if isVimeoPasswordResponse(initialResponse.data) {
                throw StreamResolutionError.vimeoPasswordRequired
            }
            throw vimeoError(from: initialResponse.data, statusCode: initialResponse.statusCode)
        }

        let passwordResponse = try await verifyVimeoPassword(
            password,
            at: link.playerURL(appending: "check-password"),
            headers: headers
        )
        if passwordResponse.statusCode == 418 || passwordResponse.isFalse {
            throw StreamResolutionError.vimeoIncorrectPassword
        }
        guard (200...299).contains(passwordResponse.statusCode) else {
            throw vimeoError(from: passwordResponse.data, statusCode: passwordResponse.statusCode)
        }
        if let stream = resolvedVimeoStream(from: passwordResponse.data, sourceURL: link.sourceURL) {
            return stream
        }

        let verifiedResponse = try await requestVimeoConfig(at: configURL, headers: headers)
        guard let stream = resolvedVimeoStream(from: verifiedResponse.data, sourceURL: link.sourceURL) else {
            throw vimeoError(from: verifiedResponse.data, statusCode: verifiedResponse.statusCode)
        }
        return stream
    }

    private static func requestVimeoConfig(
        at url: URL,
        headers: [String: String]
    ) async throws -> VimeoHTTPResponse {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        let (data, response) = try await URLSession.shared.data(for: request)
        return VimeoHTTPResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func verifyVimeoPassword(
        _ password: String,
        at url: URL,
        headers: [String: String]
    ) async throws -> VimeoHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "password", value: Data(password.utf8).base64EncodedString())
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        return VimeoHTTPResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func resolvedVimeoStream(from data: Data, sourceURL: URL) -> ResolvedStream? {
        guard let config = try? JSONDecoder().decode(VimeoConfig.self, from: data),
              let video = config.video
        else { return nil }

        let hlsURL = config.request?.files?.hls?.preferredURL
        let progressiveURL = config.request?.files?.progressive?
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .compactMap(\.url)
            .first
        guard let playbackURL = hlsURL ?? progressiveURL else { return nil }

        return ResolvedStream(
            sourceURL: sourceURL,
            playbackURL: playbackURL,
            title: video.title?.nonEmpty,
            creator: video.owner?.name?.nonEmpty,
            thumbnailURL: video.thumbnailURL
        )
    }

    private static func isVimeoPasswordResponse(_ data: Data) -> Bool {
        let response = try? JSONDecoder().decode(VimeoErrorResponse.self, from: data)
        return response?.password == true
            || response?.message?.lowercased().contains("password") == true
            || String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password")
    }

    private static func vimeoError(from data: Data, statusCode: Int) -> StreamResolutionError {
        let message = (try? JSONDecoder().decode(VimeoErrorResponse.self, from: data))?.message?.lowercased() ?? ""
        if message.contains("password") { return .vimeoPasswordRequired }
        if message.contains("refer") || message.contains("embed") { return .vimeoRefererRestricted }
        return .vimeoUnavailable(statusCode: statusCode)
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

private struct VimeoLink {
    let id: String
    let unlistedHash: String?
    let sourceURL: URL

    init(id: String, unlistedHash: String?, sourceURL: URL) throws {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw StreamResolutionError.invalidVimeoURL
        }
        self.id = id
        self.unlistedHash = unlistedHash
        self.sourceURL = sourceURL
    }

    func playerURL(appending pathComponent: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "player.vimeo.com"
        components.path = "/video/\(id)/\(pathComponent)"
        if let unlistedHash {
            components.queryItems = [URLQueryItem(name: "h", value: unlistedHash)]
        }
        return components.url!
    }
}

private struct VimeoHTTPResponse {
    let data: Data
    let statusCode: Int

    var isFalse: Bool {
        (try? JSONDecoder().decode(Bool.self, from: data)) == false
    }
}

private struct VimeoErrorResponse: Decodable {
    let message: String?
    let password: Bool?
}

private struct VimeoConfig: Decodable {
    let video: VimeoVideo?
    let request: VimeoRequest?
}

private struct VimeoVideo: Decodable {
    let title: String?
    let thumbnailURL: URL?
    let owner: VimeoOwner?

    enum CodingKeys: String, CodingKey {
        case title
        case thumbnailURL = "thumbnail_url"
        case owner
    }
}

private struct VimeoOwner: Decodable {
    let name: String?
}

private struct VimeoRequest: Decodable {
    let files: VimeoFiles?
}

private struct VimeoFiles: Decodable {
    let hls: VimeoHLS?
    let progressive: [VimeoProgressive]?
}

private struct VimeoHLS: Decodable {
    let cdns: [String: VimeoCDN]
    let defaultCDN: String?

    enum CodingKeys: String, CodingKey {
        case cdns
        case defaultCDN = "default_cdn"
    }

    var preferredURL: URL? {
        if let defaultCDN, let url = cdns[defaultCDN]?.playbackURL { return url }
        return cdns.values.compactMap(\.playbackURL).first
    }
}

private struct VimeoCDN: Decodable {
    let url: URL?
    let avcURL: URL?

    enum CodingKeys: String, CodingKey {
        case url
        case avcURL = "avc_url"
    }

    var playbackURL: URL? {
        avcURL ?? url
    }
}

private struct VimeoProgressive: Decodable {
    let url: URL?
    let height: Int?
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

enum StreamResolutionError: LocalizedError {
    case invalidStreamableURL
    case streamableUnavailable
    case invalidVimeoURL
    case vimeoPasswordRequired
    case vimeoIncorrectPassword
    case vimeoRefererRestricted
    case vimeoUnavailable(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidStreamableURL:
            return "This Streamable link does not contain a valid video ID."
        case .streamableUnavailable:
            return "This Streamable video is unavailable or has no playable MP4 file."
        case .invalidVimeoURL:
            return "This Vimeo link does not contain a valid video ID."
        case .vimeoPasswordRequired:
            return "This Vimeo video requires a password."
        case .vimeoIncorrectPassword:
            return "The Vimeo password is incorrect."
        case .vimeoRefererRestricted:
            return "Vimeo rejected the current Referer. Update it in Settings and try again."
        case .vimeoUnavailable(let statusCode):
            return statusCode == 0
                ? "This Vimeo video is unavailable or has no playable stream."
                : "Vimeo could not load this video (HTTP \(statusCode))."
        }
    }
}
