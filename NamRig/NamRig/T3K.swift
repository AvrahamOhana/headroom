//
//  T3K.swift
//  NamRig — TONE3000 API client (OAuth 2.0 PKCE) + rich, filterable capture browser.
//

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI
import UIKit

struct T3KMake: Codable { let name: String }   // makes come back as { "name": ... } — no id
struct T3KUser: Codable { let username: String?; let avatar_url: String? }

struct T3KTone: Codable, Identifiable {
    let id: Int
    let title: String
    var description: String?
    var gear: String?
    var images: [String]?
    var makes: [T3KMake]?
    var user: T3KUser?
    var models_count: Int?
    var a2_models_count: Int?
    var downloads_count: Int?
    var favorites_count: Int?

    var thumb: String? { images?.first }
    var makesText: String { (makes ?? []).map(\.name).joined(separator: ", ") }
}

struct T3KModel: Codable, Identifiable {
    let id: Int
    let name: String
    let model_url: String
}

@MainActor
@Observable
final class T3KClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let clientID = "t3k_pub_hTu9uxJ8c4u7vvPiaz2DQ-FoMul2X5m9"
    static let redirect = "namrig://oauth-callback"
    static let base = "https://www.tone3000.com/api/v1"

    private(set) var accessToken: String?
    var authError: String?
    var isLoggedIn: Bool { accessToken != nil }
    private var verifier = ""

    override init() {
        accessToken = UserDefaults.standard.string(forKey: "t3k_token")
        super.init()
    }
    func logout() { accessToken = nil; UserDefaults.standard.removeObject(forKey: "t3k_token") }

    // MARK: OAuth (PKCE)

    func login() async {
        authError = nil
        let v = Self.randomString(); verifier = v
        var c = URLComponents(string: "\(Self.base)/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: Self.challenge(v)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: Self.randomString()),
        ]
        guard let url = c.url else { return }
        do {
            let cb = try await authSession(url)
            guard let code = URLComponents(url: cb, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else { authError = "No authorization code"; return }
            try await exchange(code: code)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            authError = error.localizedDescription
        }
    }

    private func authSession(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "namrig") { cb, err in
                if let cb { cont.resume(returning: cb) } else { cont.resume(throwing: err ?? URLError(.cancelled)) }
            }
            s.presentationContextProvider = self
            s.start()
        }
    }

    private func exchange(code: String) async throws {
        var req = URLRequest(url: URL(string: "\(Self.base)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = ["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                    "redirect_uri": Self.redirect, "client_id": Self.clientID]
        req.httpBody = body.map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Tok: Codable { let access_token: String }
        let t = try JSONDecoder().decode(Tok.self, from: data)
        accessToken = t.access_token
        UserDefaults.standard.set(t.access_token, forKey: "t3k_token")
    }

    // MARK: API

    func searchTones(_ query: String, gear: String, architecture: String, page: Int = 1) async throws -> (tones: [T3KTone], totalPages: Int) {
        struct Env: Codable { let data: [T3KTone]?; let tones: [T3KTone]?; let total_pages: Int? }
        var c = URLComponents(string: "\(Self.base)/tones/search")!
        var items: [URLQueryItem] = [.init(name: "format", value: "nam"), .init(name: "page_size", value: "25"), .init(name: "page", value: "\(page)")]
        if !query.isEmpty { items.append(.init(name: "query", value: query)) }
        if !gear.isEmpty { items.append(.init(name: "gears", value: gear)) }
        if !architecture.isEmpty { items.append(.init(name: "architecture", value: architecture)) }
        c.queryItems = items
        let data = try await get(c.url!)
        let env = try? JSONDecoder().decode(Env.self, from: data)
        let list = env?.data ?? env?.tones ?? decodeList(data, key: "tones") ?? decodeList(data, key: "data") ?? (try? JSONDecoder().decode([T3KTone].self, from: data)) ?? []
        return (list, env?.total_pages ?? (list.count >= 25 ? page + 1 : page))   // fall back: full page ⇒ assume more
    }

    func models(toneID: Int, architecture: String) async throws -> [T3KModel] {
        var c = URLComponents(string: "\(Self.base)/models")!
        var items: [URLQueryItem] = [.init(name: "tone_id", value: "\(toneID)"), .init(name: "page_size", value: "30")]
        if !architecture.isEmpty { items.append(.init(name: "architecture", value: architecture)) }
        c.queryItems = items
        let data = try await get(c.url!)
        return decodeList(data, key: "models") ?? decodeList(data, key: "data") ?? (try? JSONDecoder().decode([T3KModel].self, from: data)) ?? []
    }

    func download(_ m: T3KModel) async throws -> URL {
        guard let url = URL(string: m.model_url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        if let token = accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: req)
        let safe = m.name.replacingOccurrences(of: "/", with: "-")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).nam")
        try data.write(to: dest)
        return dest
    }

    private func get(_ url: URL) async throws -> Data {
        guard let token = accessToken else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401 { logout() }
        return data
    }

    private func decodeList<T: Codable>(_ data: Data, key: String) -> [T]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj[key], let sub = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return try? JSONDecoder().decode([T].self, from: sub)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private static func randomString() -> String {
        var b = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b); return base64URL(Data(b))
    }
    private static func challenge(_ v: String) -> String { base64URL(Data(SHA256.hash(data: Data(v.utf8)))) }
    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

// MARK: - Browser

private let t3kGears: [(String, String)] = [("All gear", ""), ("Amp", "amp"), ("Amp + Cab", "amp-cab"), ("Pedal", "pedal"), ("Cab", "cab"), ("Outboard", "outboard")]
private let t3kArchs: [(String, String)] = [("A2", "2"), ("A1", "1"), ("Custom", "custom")]

struct T3KBrowser: View {
    enum Target: Identifiable { case amp, pedal; var id: Self { self } }
    let audio: AudioEngine
    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var client = T3KClient()
    @State private var query = ""
    @State private var gear: String
    @State private var arch = "2"

    init(audio: AudioEngine, target: Target = .amp) {
        self.audio = audio
        self.target = target
        _gear = State(initialValue: target == .pedal ? "pedal" : "amp-cab")
    }
    @State private var tones: [T3KTone] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var totalPages = 1
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Group {
                if !client.isLoggedIn { connect } else { browser }
            }
            .navigationTitle("TONE3000")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if client.isLoggedIn { ToolbarItem(placement: .cancellationAction) { Button("Log out") { client.logout() } } }
            }
        }
        .task { if client.isLoggedIn && tones.isEmpty { await search() } }
    }

    private var connect: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Connect your TONE3000 account to browse and download captures.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Connect TONE3000") { Task { await client.login(); if client.isLoggedIn { await search() } } }
                .buttonStyle(.borderedProminent)
            if let e = client.authError { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
        .padding(40)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                filterMenu(title: t3kGears.first { $0.1 == gear }?.0 ?? "Gear", options: t3kGears) { gear = $1; Task { await search() } }
                filterMenu(title: "Arch: \(t3kArchs.first { $0.1 == arch }?.0 ?? "")", options: t3kArchs) { arch = $1; Task { await search() } }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)

            List {
                ForEach(tones) { tone in
                    NavigationLink {
                        T3KModelList(tone: tone, arch: arch, client: client, audio: audio, target: target) { dismiss() }
                    } label: { toneRow(tone) }
                    .onAppear { if canLoadMore, tone.id == tones.last?.id { Task { await loadMore() } } }
                }
                if loadingMore { HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden) }
            }
            .overlay { if loading { ProgressView() } }
            .overlay { if !loading && tones.isEmpty { ContentUnavailableView("No captures", systemImage: "magnifyingglass", description: Text(status.isEmpty ? "Try another search or filter." : status)) } }
            .searchable(text: $query, prompt: "Search captures")
            .onSubmit(of: .search) { Task { await search() } }
        }
    }

    private func toneRow(_ tone: T3KTone) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: tone.thumb ?? "")) { img in img.resizable().scaledToFill() }
                placeholder: { ZStack { Color.gray.opacity(0.2); Image(systemName: "amplifier").foregroundStyle(.secondary) } }
                .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(tone.title).font(.headline).lineLimit(1)
                if !tone.makesText.isEmpty { Text(tone.makesText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 12) {
                    if let u = tone.user?.username { Label(u, systemImage: "person.fill").font(.caption2) }
                    if let d = tone.downloads_count { Label("\(d)", systemImage: "arrow.down").font(.caption2) }
                    if let f = tone.favorites_count { Label("\(f)", systemImage: "heart.fill").font(.caption2) }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func filterMenu(title: String, options: [(String, String)], action: @escaping (String, String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.1) { opt in Button(opt.0) { action(opt.0, opt.1) } }
        } label: {
            HStack(spacing: 4) { Text(title); Image(systemName: "chevron.down").font(.caption2) }
                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
    }

    private func search() async {
        loading = true; status = ""; page = 1; canLoadMore = true; defer { loading = false }
        do {
            let r = try await client.searchTones(query, gear: gear, architecture: arch, page: 1)
            tones = r.tones; totalPages = r.totalPages
            canLoadMore = page < totalPages
        } catch { status = error.localizedDescription; tones = []; canLoadMore = false }
    }

    private func loadMore() async {
        guard canLoadMore, !loading, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        let next = page + 1
        do {
            let r = try await client.searchTones(query, gear: gear, architecture: arch, page: next)
            let existing = Set(tones.map { $0.id })
            let fresh = r.tones.filter { !existing.contains($0.id) }
            tones.append(contentsOf: fresh)
            page = next; totalPages = r.totalPages
            canLoadMore = !fresh.isEmpty && page < totalPages   // stop on dupes (page ignored) or last page
        } catch { canLoadMore = false }
    }
}

struct T3KModelList: View {
    let tone: T3KTone
    let arch: String
    let client: T3KClient
    let audio: AudioEngine
    var target: T3KBrowser.Target = .amp
    let onDownloaded: () -> Void
    @State private var models: [T3KModel] = []
    @State private var busy: Int?

    var body: some View {
        List {
            if let desc = tone.description, !desc.isEmpty {
                Section { Text(desc).font(.callout) }
            }
            Section("Models") {
                ForEach(models) { m in
                    HStack {
                        Text(m.name)
                        Spacer()
                        if busy == m.id { ProgressView() }
                        else {
                            Button {
                                Task {
                                    busy = m.id
                                    if let url = try? await client.download(m) { audio.importModel(from: url, artworkURL: tone.thumb, gear: tone.gear, asPedal: target == .pedal); onDownloaded() }
                                    busy = nil
                                }
                            } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(tone.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { models = (try? await client.models(toneID: tone.id, architecture: arch)) ?? [] }
    }
}
