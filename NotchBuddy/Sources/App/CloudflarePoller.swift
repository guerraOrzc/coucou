import Foundation

// MARK: - CloudflareAPI

enum CloudflareAPI {
    static let base = "https://api.cloudflare.com/client/v4"

    /// The account picked in Settings. Read from UserDefaults so it is safe from any thread.
    static var accountId: String? {
        let id = UserDefaults.standard.string(forKey: "cloudflareAccountId") ?? ""
        return id.isEmpty ? nil : id
    }

    struct Failure: Error {
        let status: Int
        let message: String
    }

    /// GET a Cloudflare v4 endpoint and return its `result`. Throws with the API's own message.
    static func get(_ path: String, token: String) async throws -> Any {
        guard let url = URL(string: base + path) else { throw Failure(status: 0, message: "Bad address") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == 200, json?["success"] as? Bool != false, let result = json?["result"] else {
            let message = (json?["errors"] as? [[String: Any]])?.first?["message"] as? String
            throw Failure(status: code, message: message ?? "Cloudflare answered \(code)")
        }
        return result
    }

    /// Accounts the token can see, sorted by name.
    static func accounts(token: String) async throws -> [(id: String, name: String)] {
        let list = try await get("/accounts?per_page=50", token: token) as? [[String: Any]] ?? []
        return list.compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return (id, (a["name"] as? String) ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pages project and Worker names, for the watch list in Settings.
    static func projectNames(token: String, account: String) async throws -> [String] {
        async let pages = get("/accounts/\(account)/pages/projects", token: token)
        async let scripts = get("/accounts/\(account)/workers/scripts", token: token)
        let pageNames = ((try? await pages) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let scriptNames = CloudflareParse.scripts((try? await scripts) as? [[String: Any]] ?? []).map(\.name)
        return Array(Set(pageNames + scriptNames)).sorted()
    }

    /// Why a Pages deployment or a Workers build failed, from its log.
    static func failureReason(for deployment: CloudflareDeployment) async throws -> String? {
        guard let token = KeychainStore.shared.get("cloudflare-token"), let account = accountId else { return nil }
        switch deployment.kind {
        case .pages:
            let result = try await get(
                "/accounts/\(account)/pages/projects/\(deployment.name)/deployments/\(deployment.rawId)/history/logs",
                token: token)
            return CloudflareParse.failureReason(CloudflareParse.pagesLogLines(result as? [String: Any] ?? [:]))
        case .build:
            let result = try await get("/accounts/\(account)/builds/builds/\(deployment.rawId)/logs", token: token)
            return CloudflareParse.failureReason(CloudflareParse.buildLogLines(result as? [String: Any] ?? [:]))
        case .worker:
            return nil
        }
    }

    /// The deployment's page in the Cloudflare dashboard.
    static func dashboardURL(for deployment: CloudflareDeployment) -> URL? {
        guard let account = accountId else { return URL(string: "https://dash.cloudflare.com") }
        let name = deployment.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deployment.name
        switch deployment.kind {
        case .pages:
            return URL(string: "https://dash.cloudflare.com/\(account)/pages/view/\(name)/\(deployment.rawId)")
        case .build, .worker:
            return URL(string: "https://dash.cloudflare.com/\(account)/workers/services/view/\(name)/production")
        }
    }
}

// MARK: - CloudflarePoller
// Every 60 s: Pages projects (one call, each carries its latest deployment), then for the
// watched Workers (or the 10 most recently changed) their Workers Builds runs and deployments.
// Deployments are fetched again only when the script changed; builds while one may be running.
// On a newly finished deployment of a watched project: badge + sound on integration_cloudflare.

final class CloudflarePoller: @unchecked Sendable {
    static let shared = CloudflarePoller()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "coucou.cloudflare-poller", qos: .background)
    private var polling = false

    // Touched only on `queue`
    private var deploymentCache: [String: (modified: Date, rows: [CloudflareDeployment])] = [:]
    private var buildCache: [String: [CloudflareDeployment]] = [:]
    private var noBuilds: [String: Date] = [:]     // script → modified_on when it had no builds
    private var buildsForbidden = false            // token without Workers CI Read
    private var lastAlertId = ""
    private var silentNextPoll = true              // first poll after launch: no alert

    static let maxWorkers = 10

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 6, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.kick() }
        t.resume()
        timer = t
    }

    /// Polls right away, e.g. after the token or the account changed in Settings.
    func pollNow() {
        queue.async { [weak self] in self?.kick() }
    }

    /// The account changed: drop everything of the old one and poll again without an alert.
    @MainActor
    func accountChanged() {
        AppState.shared.cloudflareDeployments = []
        AppState.shared.cloudflareError = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.deploymentCache = [:]
            self.buildCache = [:]
            self.noBuilds = [:]
            self.buildsForbidden = false
            self.lastAlertId = ""
            self.silentNextPoll = true
            self.kick()
        }
    }

    private func kick() {
        guard !polling, !DemoEngine.isPollerPaused,
              let token = KeychainStore.shared.get("cloudflare-token"),
              let account = CloudflareAPI.accountId else { return }
        let (wanted, filter) = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                (AppState.shared.activeIntegrations.contains("integration_cloudflare"),
                 AppState.shared.cloudflareProjectFilter)
            }
        }
        guard wanted else { return }
        polling = true
        Task {
            let outcome = await self.poll(token: token, account: account, filter: filter)
            self.queue.async {
                self.polling = false
                self.apply(outcome, account: account)
            }
        }
    }

    private struct Outcome {
        var rows: [CloudflareDeployment]? = nil
        var error: String? = nil
    }

    // MARK: - Poll

    private func poll(token: String, account: String, filter: Set<String>) async -> Outcome {
        // Pages and the scripts list in parallel; a token may be allowed only one of them.
        async let pagesCall = CloudflareAPI.get("/accounts/\(account)/pages/projects", token: token)
        async let scriptsCall = CloudflareAPI.get("/accounts/\(account)/workers/scripts", token: token)
        var pages: [CloudflareDeployment] = []
        var scripts: [CloudflareScript] = []
        var failures: [CloudflareAPI.Failure] = []
        do { pages = CloudflareParse.pagesProjects(try await pagesCall as? [[String: Any]] ?? []) }
        catch let f as CloudflareAPI.Failure { failures.append(f) } catch {}
        do { scripts = CloudflareParse.scripts(try await scriptsCall as? [[String: Any]] ?? []) }
        catch let f as CloudflareAPI.Failure { failures.append(f) } catch {}

        if failures.count == 2 {
            let auth = failures.contains { $0.status == 401 || $0.status == 403 }
            return Outcome(error: auth ? "Token can't read this account" : "Can't reach Cloudflare")
        }

        // Workers to follow: the watched ones, else the most recently changed.
        let watched = filter.isEmpty
            ? Array(scripts.sorted { $0.modifiedOn > $1.modifiedOn }.prefix(Self.maxWorkers))
            : scripts.filter { filter.contains($0.name) }

        let cachedDeps = queue.sync { deploymentCache }
        let cachedBuilds = queue.sync { buildCache }
        let knownNoBuilds = queue.sync { noBuilds }
        var forbidden = queue.sync { buildsForbidden }

        var deployments: [String: [CloudflareDeployment]] = [:]
        var builds: [String: [CloudflareDeployment]] = [:]
        var newDepCache: [String: (modified: Date, rows: [CloudflareDeployment])] = [:]
        var newNoBuilds: [String: Date] = [:]

        for script in watched {
            let name = script.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? script.name

            // Deployments: only when the script changed since the last fetch
            if let cached = cachedDeps[script.name], cached.modified == script.modifiedOn {
                deployments[script.name] = cached.rows
                newDepCache[script.name] = cached
            } else if let result = try? await CloudflareAPI.get(
                "/accounts/\(account)/workers/scripts/\(name)/deployments", token: token) as? [String: Any] {
                let rows = (result["deployments"] as? [[String: Any]] ?? [])
                    .prefix(5).compactMap { CloudflareParse.workerDeployment($0, script: script.name) }
                deployments[script.name] = rows
                newDepCache[script.name] = (script.modifiedOn, rows)
            }

            // Builds: skipped for a Worker that had none and hasn't changed since
            guard !forbidden else { continue }
            if let none = knownNoBuilds[script.name], none == script.modifiedOn {
                newNoBuilds[script.name] = none
                continue
            }
            do {
                let result = try await CloudflareAPI.get(
                    "/accounts/\(account)/builds/workers/\(script.tag)/builds?per_page=5", token: token)
                let rows = (result as? [[String: Any]] ?? [])
                    .compactMap { CloudflareParse.build($0, script: script.name) }
                if rows.isEmpty { newNoBuilds[script.name] = script.modifiedOn } else { builds[script.name] = rows }
            } catch let f as CloudflareAPI.Failure where f.status == 403 || f.status == 401 {
                forbidden = true
            } catch let f as CloudflareAPI.Failure where f.status == 404 {
                newNoBuilds[script.name] = script.modifiedOn   // not connected to git
            } catch {
                if let cached = cachedBuilds[script.name] { builds[script.name] = cached }
            }
        }

        let finalForbidden = forbidden
        queue.sync {
            deploymentCache = newDepCache
            buildCache = builds
            noBuilds = newNoBuilds
            buildsForbidden = finalForbidden
        }
        return Outcome(rows: CloudflareParse.merged(pages: pages, builds: builds, workerDeployments: deployments))
    }

    // MARK: - Apply (on `queue`, hops to main)

    private func apply(_ outcome: Outcome, account: String) {
        let silent = silentNextPoll
        // A failed poll leaves the flag for the first one that brings rows
        if outcome.rows != nil { silentNextPoll = false }
        let previousAlert = lastAlertId
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The account changed while this poll was in flight: its rows are another account's
            guard account == CloudflareAPI.accountId else { return }
            let appState = AppState.shared
            appState.setIfChanged(\.cloudflareError, outcome.error)
            guard let rows = outcome.rows else { return }
            appState.setIfChanged(\.cloudflareDeployments, rows)

            // Alert once per finished deployment of a watched project.
            guard let latest = appState.cloudflareWatchedDeployments.first(where: \.isTerminal),
                  latest.id != previousAlert else { return }
            self.queue.async { self.lastAlertId = latest.id }
            guard !silent else { return }
            self.alert(latest)
        }
    }

    @MainActor
    private func alert(_ latest: CloudflareDeployment) {
        let appState = AppState.shared
        guard latest.status != .skipped, latest.status != .canceled,
              let idx = appState.tasks.firstIndex(where: { $0.id == "integration_cloudflare" }) else { return }
        let ok = latest.isSuccess
        appState.tasks[idx].state = ok ? .finished : .error
        appState.tasks[idx].steps = [latest.name]
        if appState.focusId != "integration_cloudflare" {
            appState.tasks[idx].pillBadge = ok ? .finished : .error
        }
        SoundEngine.shared.play(ok ? "finish" : "error")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Auto-clear task state after 60s (the deployments list stays)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == "integration_cloudflare" }),
                  appState.tasks[i].state == .finished || appState.tasks[i].state == .error else { return }
            appState.tasks[i].state = .idle
            appState.tasks[i].steps = []
            appState.tasks[i].pillBadge = nil
        }
    }
}
