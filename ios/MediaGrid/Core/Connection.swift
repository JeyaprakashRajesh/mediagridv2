import Foundation
import Network
import Combine
import UIKit

enum LinkState: Equatable {
    case signedOut, connecting, online, offline
}

struct WSEvent {
    let name: String
    let body: [String: Any]
}

enum APIError: LocalizedError {
    case server(String), notSignedIn, bad
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .notSignedIn: return "Not signed in"
        case .bad: return "Unexpected response from your PC"
        }
    }
}

/// Talks to the MediaGrid PC app over Wi-Fi or Tailscale.
@MainActor
final class Connection: ObservableObject {
    static let shared = Connection()

    @Published var host: String = UserDefaults.standard.string(forKey: "mg.host") ?? ""
    @Published var pcName: String = UserDefaults.standard.string(forKey: "mg.pcName") ?? ""
    @Published var email: String = UserDefaults.standard.string(forKey: "mg.email") ?? ""
    @Published var state: LinkState = .signedOut
    @Published var discovered: [DiscoveredPC] = []
    @Published var knownHosts: [String] = UserDefaults.standard.stringArray(forKey: "mg.hosts") ?? []

    let events = PassthroughSubject<WSEvent, Never>()
    private(set) var token: String = Keychain.get("mg.token") ?? ""

    private var ws: URLSessionWebSocketTask?
    private var retry = 0
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceType: NWInterface.InterfaceType?
    private var statusTimer: Timer?
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    var isSignedIn: Bool { !token.isEmpty && !host.isEmpty }
    var base: String { "http://\(host)" }

    init() {
        if isSignedIn { state = .connecting }
        startNetworkMonitoring()
        syncToGroup()
    }

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let currentType: NWInterface.InterfaceType = path.usesInterfaceType(.wifi) ? .wifi :
                                                           path.usesInterfaceType(.cellular) ? .cellular :
                                                           path.usesInterfaceType(.wiredEthernet) ? .wiredEthernet : .other
                let statusChanged = (self.lastPathStatus != path.status)
                let ifaceChanged = (self.lastInterfaceType != currentType)
                let firstCheck = (self.lastPathStatus == nil)
                self.lastPathStatus = path.status
                self.lastInterfaceType = currentType

                if !firstCheck && path.status == .satisfied && (statusChanged || ifaceChanged) && self.isSignedIn {
                    // Network transitioned (e.g. left Wi-Fi -> joined Cellular/VPN or vice-versa)
                    self.retry = 0
                    self.ws?.cancel()
                    self.ws = nil
                    await self.findReachableHost()
                    self.connect()
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.pathMonitor = monitor
    }

    // MARK: URLs & requests

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(string: base + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "t", value: token))
        c.queryItems = items
        return c.url!
    }

    func request(_ path: String, method: String = "GET", query: [String: String] = [:], json: Any? = nil) async throws -> Data {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session.data(for: r)
        try check(d, resp)
        return d
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path, query: query))
    }

    func post(_ path: String, query: [String: String] = [:], json: Any) async throws {
        _ = try await request(path, method: "POST", query: query, json: json)
    }

    func upload(_ path: String, query: [String: String], file: URL) async throws {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = "POST"
        r.timeoutInterval = 3600
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await session.upload(for: r, fromFile: file)
        try check(d, resp)
    }

    func upload(_ path: String, query: [String: String], data: Data) async throws {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await session.upload(for: r, from: data)
        try check(d, resp)
    }

    private func check(_ d: Data, _ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw APIError.bad }
        if h.statusCode == 401 && !token.isEmpty {
            signOut()
            throw APIError.server("Signed out by your PC. Please sign in again.")
        }
        guard (200..<300).contains(h.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw APIError.server(msg ?? "Error \(h.statusCode)")
        }
    }

    // MARK: Sign in

    static func normalize(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        if h.hasSuffix("/") { h.removeLast() }
        if !h.contains(":") { h += ":47800" }
        return h
    }

    func ping(_ host: String, timeout: TimeInterval = 3) async -> ServerInfo? {
        guard let u = URL(string: "http://\(host)/api/ping") else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        guard let (d, _) = try? await session.data(for: r) else { return nil }
        let info = try? JSONDecoder().decode(ServerInfo.self, from: d)
        if let m = info?.mac { UserDefaults.standard.set(m, forKey: "mg.pcMac") }   // for Wake-on-LAN
        return info
    }

    func signIn(host raw: String, email: String, password: String) async throws {
        let h = Self.normalize(raw)
        guard let info = await ping(h) else { throw APIError.server("Can't reach MediaGrid at \(h). Is the PC app running and on the same Wi-Fi or Tailscale network?") }
        guard info.account else { throw APIError.server("Create your account in MediaGrid on your PC first (Profile tab).") }
        var r = URLRequest(url: URL(string: "http://\(h)/api/login")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password, "device": UIDevice.current.name])
        let (d, resp) = try await session.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let tok = obj["token"] as? String else {
            throw APIError.server(obj["error"] as? String ?? "Sign in failed")
        }
        token = tok
        Keychain.set("mg.token", tok)
        self.host = h
        self.email = email
        self.pcName = info.name
        remember(h)
        UserDefaults.standard.set(h, forKey: "mg.host")
        UserDefaults.standard.set(email, forKey: "mg.email")
        UserDefaults.standard.set(info.name, forKey: "mg.pcName")
        syncToGroup()
        state = .connecting
        connect()
    }

    func signOut() {
        token = ""
        Keychain.delete("mg.token")
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        state = .signedOut
        if let g = UserDefaults(suiteName: "group.com.jeyaprakash.mediagrid") {
            g.removeObject(forKey: "mg.token")
        }
    }

    func remember(_ h: String) {
        if !knownHosts.contains(h) { knownHosts.insert(h, at: 0) }
        UserDefaults.standard.set(knownHosts, forKey: "mg.hosts")
        syncToGroup()
    }

    func syncToGroup() {
        if let g = UserDefaults(suiteName: "group.com.jeyaprakash.mediagrid") {
            g.set(host, forKey: "mg.host")
            g.set(token, forKey: "mg.token")
            g.set(pcName, forKey: "mg.pcName")
            g.set(knownHosts, forKey: "mg.hosts")
        }
    }

    // MARK: WebSocket

    func connect() {
        guard isSignedIn else { state = .signedOut; return }
        ws?.cancel()
        var c = URLComponents(string: "ws://\(host)/ws")!
        c.queryItems = [URLQueryItem(name: "t", value: token)]
        let task = session.webSocketTask(with: c.url!)
        ws = task
        task.resume()
        receive(task)
        Task { await sendStatus() }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { _ in
            Task { @MainActor in await Connection.shared.sendStatus() }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.ws else { return }
                switch result {
                case .success(let msg):
                    if self.state != .online { self.state = .online; self.retry = 0 }
                    if case .string(let s) = msg,
                       let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                       let name = obj["event"] as? String {
                        self.events.send(WSEvent(name: name, body: obj))
                    }
                    self.receive(task)
                case .failure:
                    self.state = .offline
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard isSignedIn else { return }
        retry += 1
        let delay = min(30.0, pow(1.6, Double(retry)))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await self.findReachableHost()
            self.connect()
        }
    }

    /// Switch between LAN / Tailscale addresses automatically.
    func findReachableHost() async {
        var candidates: [String] = []
        if !host.isEmpty { candidates.append(host) }
        for k in knownHosts where !candidates.contains(k) { candidates.append(k) }
        for d in discovered where (pcName.isEmpty || d.name == pcName) {
            let ep = "\(d.host):\(d.port)"
            if !candidates.contains(ep) { candidates.append(ep) }
        }
        guard !candidates.isEmpty else { return }

        // Fast path: if the currently selected host is responsive within 1.2s, stay on it
        if !host.isEmpty, await ping(host, timeout: 1.2) != nil {
            return
        }

        // Concurrently ping all candidate addresses
        let reachable = await withTaskGroup(of: (String, ServerInfo, Bool)?.self) { group in
            for candidate in candidates {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    if let info = await self.ping(candidate, timeout: 2.0) {
                        let isLAN = !candidate.hasPrefix("100.")
                        return (candidate, info, isLAN)
                    }
                    return nil
                }
            }
            var responders: [(host: String, info: ServerInfo, isLAN: Bool)] = []
            for await res in group {
                if let res {
                    responders.append(res)
                }
            }
            return responders
        }

        guard !reachable.isEmpty else { return }

        // Prefer LAN over Tailscale if both are reachable (lowest latency on local Wi-Fi)
        let selected: String
        if let lanHost = reachable.first(where: { $0.isLAN })?.host {
            selected = lanHost
        } else {
            selected = reachable[0].host
        }

        if selected != self.host {
            self.host = selected
            UserDefaults.standard.set(selected, forKey: "mg.host")
            remember(selected)
        }
    }

    func send(_ obj: [String: Any]) {
        guard let ws, let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        ws.send(.string(s)) { _ in }
    }

    func sendStatus() async {
        guard state == .online || state == .connecting else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        var o: [String: Any] = [
            "type": "status",
            "model": UIDevice.current.model + " · iOS " + UIDevice.current.systemVersion,
            "battery": Double(UIDevice.current.batteryLevel),
            "charging": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
        ]
        if let t = Player.shared.current {
            o["nowPlaying"] = ["title": t.title, "artist": t.artist, "album": t.album, "playing": Player.shared.isPlaying]
        }
        send(o)
    }

    func resume() {
        guard isSignedIn else { return }
        Task {
            await findReachableHost()
            if state != .online { connect() }
        }
    }

    // MARK: Bonjour discovery

    func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_mediagrid._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                Self.resolve(r.endpoint) { host, port in
                    Task { @MainActor in
                        guard let self else { return }
                        let pc = DiscoveredPC(name: name, host: host, port: port)
                        if !self.discovered.contains(pc) { self.discovered.append(pc) }
                    }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    nonisolated private static func resolve(_ ep: NWEndpoint, _ done: @escaping (String, Int) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: ep, using: params)
        c.stateUpdateHandler = { st in
            if case .ready = st {
                if case let .hostPort(h, p)? = c.currentPath?.remoteEndpoint {
                    var hs = "\(h)"
                    if let i = hs.firstIndex(of: "%") { hs = String(hs[..<i]) }
                    done(hs, Int(p.rawValue))
                }
                c.cancel()
            } else if case .failed = st { c.cancel() }
        }
        c.start(queue: .global())
    }
}

enum Keychain {
    static func set(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }
}
