//
//  T3K.swift
//  NamRig — TONE3000 API client (OAuth 2.0 PKCE + refresh tokens) and the capture browser:
//  Search (sort / gear / architecture / calibrated / verified), Trending, Favorites, My tones,
//  Downloaded — with favorite toggling, download progress and "in library" badges.
//

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct T3KMake: Codable { let name: String }
struct T3KTag: Codable { let name: String }
struct T3KUser: Codable { let username: String?; let avatar_url: String? }

struct T3KTone: Codable, Identifiable {
    let id: Int
    let title: String
    var description: String?
    var gear: String?
    var images: [String]?
    var makes: [T3KMake]?
    var tags: [T3KTag]?
    var user: T3KUser?
    var models_count: Int?
    var a2_models_count: Int?
    var downloads_count: Int?
    var favorites_count: Int?
    var is_favorited: Bool?
    var is_favorite: Bool?
    var isFav: Bool { is_favorite ?? is_favorited ?? false }
    var calibrated: Bool?
    var verified: Bool?

    var thumb: String? { images?.first }
    var makesText: String { (makes ?? []).map(\.name).joined(separator: ", ") }
    var tagsText: String { (tags ?? []).map(\.name).joined(separator: " · ") }
}

struct T3KModel: Codable, Identifiable {
    let id: Int
    let name: String
    let model_url: String
    var size: String?
    var architecture_version: String?
    var architecture: String?
    var arch: String? { architecture_version ?? architecture }
}

struct T3KProfile: Codable { let username: String?; let avatar_url: String?; let tones_count: Int?; let favorites_count: Int? }

/// Which local tone IDs have been downloaded (badge + "Downloaded" tab fallback).
enum T3KLibrary {
    private static let key = "t3k_downloaded_ids"
    static var ids: Set<Int> {
        get { Set((UserDefaults.standard.array(forKey: key) as? [Int]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }
    static func mark(_ id: Int) { var s = ids; s.insert(id); ids = s }
}

@MainActor
@Observable
final class T3KClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let clientID = "t3k_pub_hTu9uxJ8c4u7vvPiaz2DQ-FoMul2X5m9"
    static let redirect = "namrig://oauth-callback"
    static let base = "https://www.tone3000.com/api/v1"

    private(set) var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?
    var authError: String?
    private(set) var profile: T3KProfile?
    var isLoggedIn: Bool { accessToken != nil }
    private var verifier = ""

    override init() {
        let d = UserDefaults.standard
        accessToken = d.string(forKey: "t3k_token")
        refreshToken = d.string(forKey: "t3k_refresh")
        expiresAt = d.object(forKey: "t3k_expires") as? Date
        super.init()
    }
    func logout() {
        accessToken = nil; refreshToken = nil; expiresAt = nil; profile = nil
        for k in ["t3k_token", "t3k_refresh", "t3k_expires"] { UserDefaults.standard.removeObject(forKey: k) }
    }

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
            try await token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": Self.redirect])
            await loadProfile()
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

    private func token(_ fields: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "\(Self.base)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = fields; body["client_id"] = Self.clientID
        req.httpBody = body.map { "\($0)=\(Self.formEncode($1))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw NSError(domain: "T3K", code: 1, userInfo: [NSLocalizedDescriptionKey: "Login failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        struct Tok: Codable { let access_token: String; let refresh_token: String?; let expires_in: Double? }
        let t = try JSONDecoder().decode(Tok.self, from: data)
        accessToken = t.access_token
        if let r = t.refresh_token { refreshToken = r }
        expiresAt = t.expires_in.map { Date().addingTimeInterval($0 - 60) }
        let d = UserDefaults.standard
        d.set(accessToken, forKey: "t3k_token"); d.set(refreshToken, forKey: "t3k_refresh"); d.set(expiresAt, forKey: "t3k_expires")
    }

    /// Refresh if expired (or on demand). Returns false when no refresh is possible → caller logs out.
    private func refreshIfNeeded(force: Bool = false) async -> Bool {
        guard let r = refreshToken else { return false }
        if !force, let e = expiresAt, e > Date() { return true }
        if !force, expiresAt == nil { return true }
        do { try await token(["grant_type": "refresh_token", "refresh_token": r]); return true } catch { return false }
    }

    func loadProfile() async {
        if let data = try? await get(URL(string: "\(Self.base)/user")!) {
            profile = (try? JSONDecoder().decode(T3KProfile.self, from: data)) ?? decodeObj(data, key: "user")
        }
    }

    // MARK: API

    struct Page { var tones: [T3KTone]; var totalPages: Int }

    func searchTones(_ query: String, gear: String, architecture: String, sort: String, format: String = "nam",
                     calibrated: Bool = false, verified: Bool = false, page: Int = 1) async throws -> Page {
        var c = URLComponents(string: "\(Self.base)/tones/search")!
        var items: [URLQueryItem] = [.init(name: "page_size", value: "25"), .init(name: "page", value: "\(page)")]
        if !format.isEmpty { items.append(.init(name: "format", value: format)) }
        if !query.isEmpty { items.append(.init(name: "query", value: query)) }
        if !gear.isEmpty { items.append(.init(name: "gears", value: gear)) }
        if !architecture.isEmpty { items.append(.init(name: "architecture", value: architecture)) }
        if !sort.isEmpty { items.append(.init(name: "sort", value: sort)) }
        if calibrated { items.append(.init(name: "calibrated", value: "true")) }
        if verified { items.append(.init(name: "verified", value: "true")) }
        c.queryItems = items
        return parsePage(try await get(c.url!), page: page)
    }

    /// created | favorited | downloaded (the user's own lists).
    func userTones(_ list: String, gear: String, page: Int = 1) async throws -> Page {
        var c = URLComponents(string: "\(Self.base)/tones/\(list)")!
        var items: [URLQueryItem] = [.init(name: "page_size", value: "25"), .init(name: "page", value: "\(page)")]
        if !gear.isEmpty { items.append(.init(name: "gear", value: gear)) }
        c.queryItems = items
        return parsePage(try await get(c.url!), page: page)
    }

    func trending(gear: String) async throws -> Page {
        var c = URLComponents(string: "\(Self.base)/tones/trending")!
        if !gear.isEmpty { c.queryItems = [.init(name: "gear", value: gear)] }
        var p = parsePage(try await get(c.url!), page: 1); p.totalPages = 1
        return p
    }

    private func parsePage(_ data: Data, page: Int) -> Page {
        struct Env: Codable { let data: [T3KTone]?; let tones: [T3KTone]?; let total_pages: Int?; let pages: Int? }
        let env = try? JSONDecoder().decode(Env.self, from: data)
        let list = env?.data ?? env?.tones ?? decodeList(data, key: "tones") ?? decodeList(data, key: "data") ?? (try? JSONDecoder().decode([T3KTone].self, from: data)) ?? []
        let total = env?.total_pages ?? env?.pages ?? (list.count >= 25 ? page + 1 : page)
        return Page(tones: list, totalPages: total)
    }

    func models(toneID: Int, architecture: String) async throws -> [T3KModel] {
        var c = URLComponents(string: "\(Self.base)/models")!
        var items: [URLQueryItem] = [.init(name: "tone_id", value: "\(toneID)"), .init(name: "page_size", value: "50")]
        if !architecture.isEmpty { items.append(.init(name: "architecture", value: architecture)) }
        c.queryItems = items
        let data = try await get(c.url!)
        return decodeList(data, key: "models") ?? decodeList(data, key: "data") ?? (try? JSONDecoder().decode([T3KModel].self, from: data)) ?? []
    }

    func setFavorite(_ toneID: Int, _ on: Bool) async -> Bool {
        guard await refreshIfNeeded(), let token = accessToken else { return false }
        var req = URLRequest(url: URL(string: "\(Self.base)/tones/\(toneID)/favorite")!)
        req.httpMethod = on ? "PUT" : "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Download a model file with progress (0…1). Returns the temp file URL.
    func download(_ m: T3KModel, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let url = URL(string: m.model_url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        if let token = accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let total = resp.expectedContentLength
        var data = Data(); data.reserveCapacity(total > 0 ? Int(total) : 1 << 20)
        var lastPct = -1
        for try await b in bytes {
            data.append(b)
            if total > 0 {
                let pct = Int(Double(data.count) / Double(total) * 50)
                if pct != lastPct { lastPct = pct; progress(Double(data.count) / Double(total)) }
            }
        }
        progress(1)
        let safe = m.name.replacingOccurrences(of: "/", with: "-")
        let ext = (URL(string: m.model_url)?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "nam"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).\(ext)")
        try data.write(to: dest)
        return dest
    }

    private func get(_ url: URL) async throws -> Data {
        guard await refreshIfNeeded(), let token = accessToken else { logout(); throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            // Token rejected → one forced refresh, then retry; otherwise log out.
            if await refreshIfNeeded(force: true), let t = accessToken {
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                (data, resp) = try await URLSession.shared.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 401 { logout() }
            } else { logout() }
        }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400, code != 429 {
            throw NSError(domain: "T3K", code: code, userInfo: [NSLocalizedDescriptionKey: "TONE3000 error \(code)"])
        }
        if (resp as? HTTPURLResponse)?.statusCode == 429 {
            throw NSError(domain: "T3K", code: 429, userInfo: [NSLocalizedDescriptionKey: "TONE3000 rate limit — wait a minute and try again."])
        }
        return data
    }

    private func decodeList<T: Codable>(_ data: Data, key: String) -> [T]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj[key], let sub = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return try? JSONDecoder().decode([T].self, from: sub)
    }
    private func decodeObj<T: Codable>(_ data: Data, key: String) -> T? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj[key], let d = try? JSONSerialization.data(withJSONObject: sub) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
            #else
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
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

private let t3kGears: [(String, String)] = [("All gear", ""), ("Amp", "amp"), ("Amp + Cab", "amp-cab"), ("Pedal", "pedal"), ("Cab", "cab"), ("Outboard", "outboard"), ("Full rig", "full-rig")]
private let t3kArchs: [(String, String)] = [("A2", "2"), ("A1", "1"), ("Custom", "custom"), ("Any", "")]
private let t3kSorts: [(String, String)] = [("Best match", "best-match"), ("Trending", "trending"), ("Newest", "newest"), ("Most downloaded", "downloads-all-time"), ("Oldest", "oldest")]

struct T3KBrowser: View {
    enum Target: Identifiable { case amp, pedal, cab; var id: Self { self } }
    enum Tab: String, CaseIterable, Identifiable { case search = "Search", trending = "Trending", favorites = "Favorites", mine = "Mine", downloaded = "Downloaded"; var id: Self { self } }
    let audio: AudioEngine
    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var client = T3KClient()
    @State private var query = ""
    @State private var gear: String
    @State private var arch: String
    @State private var sort = "best-match"
    @State private var calibratedOnly = false
    @State private var verifiedOnly = false
    @State private var tab: Tab = .search

    init(audio: AudioEngine, target: Target = .amp) {
        self.audio = audio
        self.target = target
        let isCab = target == .cab
        _gear = State(initialValue: target == .pedal ? "pedal" : (isCab ? "cab" : "amp-cab"))
        _arch = State(initialValue: isCab ? "" : "2")   // cab IRs have no NAM architecture
    }
    @State private var tones: [T3KTone] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var totalPages = 1
    @State private var status = ""
    @State private var library = T3KLibrary.ids

    var body: some View {
        NavigationStack {
            Group {
                if !client.isLoggedIn { connect } else { browser }
            }
            .navigationTitle("TONE3000")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if client.isLoggedIn {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            if let u = client.profile?.username { Text("@\(u)") }
                            Button("Log out", role: .destructive) { client.logout() }
                        } label: { Image(systemName: "person.crop.circle") }
                    }
                }
            }
        }
        .sheetSize([.large], mac: CGSize(width: 760, height: 820))
        .task {
            if client.isLoggedIn {
                if client.profile == nil { await client.loadProfile() }
                if tones.isEmpty { await search() }
            }
        }
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
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
                .onChange(of: tab) { _, _ in Task { await search() } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterMenu(title: t3kGears.first { $0.1 == gear }?.0 ?? "Gear", options: t3kGears) { gear = $1; Task { await search() } }
                    if target != .cab {
                        filterMenu(title: "Arch: \(t3kArchs.first { $0.1 == arch }?.0 ?? "Any")", options: t3kArchs) { arch = $1; Task { await search() } }
                    }
                    if tab == .search {
                        filterMenu(title: t3kSorts.first { $0.1 == sort }?.0 ?? "Sort", options: t3kSorts) { sort = $1; Task { await search() } }
                        chip("Calibrated", on: $calibratedOnly)
                        chip("Verified", on: $verifiedOnly)
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }

            List {
                ForEach(tones) { tone in
                    NavigationLink {
                        T3KToneDetail(tone: tone, arch: arch, client: client, audio: audio, target: target,
                                      onDownloaded: { T3KLibrary.mark(tone.id); library = T3KLibrary.ids; dismiss() })
                    } label: { toneRow(tone) }
                    .swipeActions(edge: .trailing) {
                        Button { toggleFavorite(tone) } label: {
                            Label(tone.isFav ? "Unfavorite" : "Favorite", systemImage: tone.isFav ? "heart.slash" : "heart")
                        }.tint(.pink)
                    }
                    .onAppear { if canLoadMore, tone.id == tones.last?.id { Task { await loadMore() } } }
                }
                if loadingMore { HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden) }
            }
            .listStyle(.plain)
            .overlay { if loading { ProgressView() } }
            .overlay { if !loading && tones.isEmpty { ContentUnavailableView("No captures", systemImage: "magnifyingglass", description: Text(status.isEmpty ? "Try another search or filter." : status)) } }
            .searchable(text: $query, prompt: "Search captures, makes, creators")
            .onSubmit(of: .search) { tab = .search; Task { await search() } }
            // Live search: re-query 0.4 s after the last keystroke (Return isn't reliable on every platform).
            .task(id: query) {
                guard !query.isEmpty || tab == .search else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                if tab != .search { tab = .search } else { await search() }
            }
            .refreshable { await search() }
        }
    }

    private func toneRow(_ tone: T3KTone) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: tone.thumb ?? "")) { img in img.resizable().scaledToFill() }
                placeholder: { ZStack { Color.gray.opacity(0.2); Image(systemName: "amplifier").foregroundStyle(.secondary) } }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tone.title).font(.headline).lineLimit(1)
                    if tone.verified == true { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue) }
                    if tone.calibrated == true { Image(systemName: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(.orange) }
                }
                if !tone.makesText.isEmpty { Text(tone.makesText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 10) {
                    if let g = tone.gear { Text(g.uppercased()).font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                    if let u = tone.user?.username { Label(u, systemImage: "person.fill").font(.caption2) }
                    if let d = tone.downloads_count { Label("\(d)", systemImage: "arrow.down").font(.caption2) }
                    if let f = tone.favorites_count { Label("\(f)", systemImage: tone.isFav ? "heart.fill" : "heart").font(.caption2).foregroundStyle(tone.isFav ? .pink : .secondary) }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if library.contains(tone.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }

    private func chip(_ title: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle(); Task { await search() } } label: {
            Text(title).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(on.wrappedValue ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
        }.buttonStyle(.plain)
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

    private func toggleFavorite(_ tone: T3KTone) {
        let on = !tone.isFav
        Task {
            if await client.setFavorite(tone.id, on), let i = tones.firstIndex(where: { $0.id == tone.id }) {
                tones[i].is_favorite = on
                tones[i].favorites_count = max(0, (tones[i].favorites_count ?? 0) + (on ? 1 : -1))
            }
        }
    }

    private func fetch(page p: Int) async throws -> T3KClient.Page {
        let fmt = target == .cab ? "" : "nam"
        switch tab {
        case .search: return try await client.searchTones(query, gear: gear, architecture: arch, sort: sort, format: fmt, calibrated: calibratedOnly, verified: verifiedOnly, page: p)
        case .trending: return try await client.trending(gear: gear)
        case .favorites: return try await client.userTones("favorited", gear: gear, page: p)
        case .mine: return try await client.userTones("created", gear: gear, page: p)
        case .downloaded: return try await client.userTones("downloaded", gear: gear, page: p)
        }
    }

    private func search() async {
        loading = true; status = ""; page = 1; canLoadMore = true; defer { loading = false }
        do {
            let r = try await fetch(page: 1)
            tones = r.tones; totalPages = r.totalPages
            canLoadMore = page < totalPages
        } catch { status = error.localizedDescription; tones = []; canLoadMore = false }
    }

    private func loadMore() async {
        guard canLoadMore, !loading, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        let next = page + 1
        do {
            let r = try await fetch(page: next)
            let existing = Set(tones.map { $0.id })
            let fresh = r.tones.filter { !existing.contains($0.id) }
            tones.append(contentsOf: fresh)
            page = next; totalPages = r.totalPages
            canLoadMore = !fresh.isEmpty && page < totalPages
        } catch { canLoadMore = false }
    }
}

/// Tone page: cover, description, tags, creator, favorite button, and the model list with per-file download progress.
struct T3KToneDetail: View {
    @State var tone: T3KTone
    let arch: String
    let client: T3KClient
    let audio: AudioEngine
    var target: T3KBrowser.Target = .amp
    let onDownloaded: () -> Void
    @State private var models: [T3KModel] = []
    @State private var busy: Int?
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var loadingModels = true

    var body: some View {
        List {
            Section {
                if let img = tone.thumb, let url = URL(string: img) {
                    AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.gray.opacity(0.15).frame(height: 160) }
                        .clipShape(RoundedRectangle(cornerRadius: 12)).listRowInsets(EdgeInsets())
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !tone.makesText.isEmpty { Text(tone.makesText).font(.subheadline.weight(.semibold)) }
                        if let u = tone.user?.username { Label(u, systemImage: "person.fill").font(.caption).foregroundStyle(.secondary) }
                        if !tone.tagsText.isEmpty { Text(tone.tagsText).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button {
                        let on = !tone.isFav
                        Task { if await client.setFavorite(tone.id, on) { tone.is_favorite = on; tone.favorites_count = max(0, (tone.favorites_count ?? 0) + (on ? 1 : -1)) } }
                    } label: {
                        Label("\(tone.favorites_count ?? 0)", systemImage: tone.isFav ? "heart.fill" : "heart")
                            .foregroundStyle(tone.isFav ? .pink : .secondary)
                    }.buttonStyle(.bordered)
                }
                if let desc = tone.description, !desc.isEmpty { Text(desc).font(.callout) }
            }
            Section(target == .cab ? "Impulse responses" : "Models") {
                if loadingModels { HStack { Spacer(); ProgressView(); Spacer() } }
                else if models.isEmpty { Text("No files for this architecture — try Arch: Any.").font(.caption).foregroundStyle(.secondary) }
                ForEach(models) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).lineLimit(2)
                            HStack(spacing: 8) {
                                if let s = m.size { Text(s).font(.caption2).foregroundStyle(.secondary) }
                                if let a = m.arch { Text("A\(a)").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer()
                        if busy == m.id {
                            ProgressView(value: progress).progressViewStyle(.circular).frame(width: 26)
                        } else {
                            Button { download(m) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                                .buttonStyle(.plain).disabled(busy != nil)
                        }
                    }
                }
            }
            if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
        }
        .navigationTitle(tone.title)
        .inlineTitle()
        .task {
            models = (try? await client.models(toneID: tone.id, architecture: arch)) ?? []
            loadingModels = false
        }
    }

    private func download(_ m: T3KModel) {
        Task {
            busy = m.id; progress = 0; error = nil
            do {
                let url = try await client.download(m) { progress = $0 }
                switch target {
                case .cab: audio.loadCabIR(from: url)
                case .amp: audio.importModel(from: url, artworkURL: tone.thumb, gear: tone.gear, slot: .amp)
                case .pedal: audio.importModel(from: url, artworkURL: tone.thumb, gear: tone.gear, slot: .pedal)
                }
                Haptics.success()
                onDownloaded()
            } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}
