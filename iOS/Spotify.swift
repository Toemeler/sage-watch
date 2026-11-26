import SwiftUI
import AuthenticationServices
import CryptoKit
import UIKit

/// What Spotify is playing, for the cover on the watch face. Uses the Spotify Web API with the user's own developer
/// app (Client ID pasted in Sage) and PKCE login, scope user-read-currently-playing — this works on Spotify Free.
/// Playback control stays with the system Now Playing controls on the watch (the API's control endpoints need Premium).
@MainActor
final class Spotify: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Spotify()
    static let redirect = "sage-spotify://callback"

    @Published var clientID: String = UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "spotifyClientID") }
    }
    @Published private(set) var connected = Keychain.get("spotifyRefresh") != nil
    @Published private(set) var status = ""

    private var accessToken: String?
    private var expires = Date.distantPast
    private var authSession: ASWebAuthenticationSession?

    // MARK: login (PKCE)

    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { status = "Paste your Client ID first."; return }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: "user-read-currently-playing user-read-playback-state"),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge)
        ]
        let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "sage-spotify") { url, error in
            Task { @MainActor in
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.status = error == nil ? "Spotify did not return a code." : "Login cancelled."
                    return
                }
                await self.exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                                     "client_id": id, "code_verifier": verifier])
            }
        }
        session.presentationContextProvider = self
        authSession = session
        session.start()
    }

    func disconnect() {
        Keychain.set("spotifyRefresh", nil); accessToken = nil; connected = false; status = "Disconnected."
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func exchange(_ form: [String: String]) async {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            status = "Spotify login failed. Check the Client ID and the redirect URI."
            return
        }
        accessToken = token
        expires = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { Keychain.set("spotifyRefresh", refresh) }
        connected = true
        status = "Connected."
    }

    private func token() async -> String? {
        if let accessToken, Date() < expires { return accessToken }
        guard let refresh = Keychain.get("spotifyRefresh") else { return nil }
        await exchange(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        return accessToken
    }

    // MARK: now playing

    struct Track { var title: String; var artist: String; var artURL: String; var playing: Bool }

    func nowPlaying() async -> Track? {
        guard connected, let token = await token() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=episode")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = json["item"] as? [String: Any] else { return nil }
        let title = item["name"] as? String ?? ""
        let artist = ((item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", "))
            ?? ((item["show"] as? [String: Any])?["name"] as? String ?? "")
        let images = ((item["album"] as? [String: Any])?["images"] as? [[String: Any]]) ?? (item["images"] as? [[String: Any]]) ?? []
        // the 300 px image when there is one (Spotify lists 640, 300, 64)
        let art = images.first { ($0["width"] as? Int ?? 0) <= 300 && ($0["width"] as? Int ?? 0) >= 200 }?["url"] as? String
            ?? images.first?["url"] as? String ?? ""
        return Track(title: title, artist: artist, artURL: art, playing: json["is_playing"] as? Bool ?? false)
    }

    private var artCache: (url: String, data: Data)?

    /// the cover as a small JPEG for the watch (~150 px, a few KB)
    func art(_ url: String) async -> Data? {
        if let c = artCache, c.url == url { return c.data }
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) else { return nil }
        let size = CGSize(width: 150, height: 150)
        let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.75) else { return nil }
        artCache = (url, jpeg)
        return jpeg
    }

    /// adds the Spotify track to the watch's audio reply; the cover only when the watch does not have it yet
    func nowPlayingReply(watchHas: String?) async -> [String: Any] {
        var reply: [String: Any] = [:]
        guard let t = await nowPlaying() else { return reply }
        reply["title"] = t.title
        reply["artist"] = t.artist
        reply["spotifyPlaying"] = t.playing
        reply["artURL"] = t.artURL
        if !t.artURL.isEmpty, t.artURL != watchHas, let data = await art(t.artURL) { reply["art"] = data }
        return reply
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal keychain wrapper for the Spotify refresh token.
enum Keychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Spotify setup in the Faces tab: steps, Client ID, connect.
struct SpotifyCard: View {
    @ObservedObject var spotify = Spotify.shared

    var body: some View {
        Card {
            Eyebrow(text: "Spotify cover on the watch")
            if spotify.connected {
                Text("Connected").font(Theme.serif(22)).foregroundStyle(Theme.ivory)
                Text("While Spotify plays, the cover shows under the clock. Tap it on the watch for pause, skip and back.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button("Disconnect", role: .destructive) { spotify.disconnect() }.font(.callout)
            } else {
                Text("1. On developer.spotify.com › Dashboard › Create app.\n2. Redirect URI: \(Spotify.redirect)\n3. API: Web API. Save, open Settings, copy the Client ID.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                TextField("Client ID", text: $spotify.clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.callout, design: .monospaced))
                    .padding(8).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Button("Connect Spotify") { spotify.connect() }
                    .buttonStyle(.borderedProminent).tint(Color(hex: 0x1DB954))
            }
            if !spotify.status.isEmpty { Text(spotify.status).font(.caption).foregroundStyle(Theme.sage) }
        }
    }
}
