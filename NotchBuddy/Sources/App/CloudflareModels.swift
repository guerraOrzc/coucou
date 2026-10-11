import Foundation

// MARK: - Cloudflare
// One row of the Cloudflare card: a Pages deployment, a Workers Builds run (git-connected
// Workers) or a Worker deployment (wrangler, dashboard or API). Parsing is kept free of
// AppKit and network so tests/CloudflareTests.swift can run it on its own.

struct CloudflareDeployment: Identifiable, Equatable {
    enum Kind: String { case pages, build, worker }
    enum Status: Equatable { case building, success, failure, canceled, skipped }

    let kind: Kind
    let rawId: String         // Pages deployment id, build uuid or Worker deployment id
    let name: String          // Pages project or Worker name
    let status: Status
    let createdAt: Date
    var branch: String? = nil
    var commitMessage: String? = nil
    var author: String? = nil
    var url: String? = nil          // full https URL of the deployment or preview, when known
    var environment: String? = nil  // Pages: "production" / "preview"
    var source: String? = nil       // Worker deployment: "wrangler", "dash", "api"…
    var stage: String? = nil        // Pages: queued, initialize, clone_repo, build, deploy

    /// Unique across kinds: a Pages deployment and a build can't collide in the list.
    var id: String { "\(kind.rawValue):\(rawId)" }

    var isSuccess: Bool { status == .success }
    var isBuilding: Bool { status == .building }
    var isTerminal: Bool { status != .building }

    var kindLabel: String {
        switch kind {
        case .pages:  return "Pages"
        case .build:  return "Workers Build"
        case .worker: return "Worker"
        }
    }

    var statusLabel: String {
        switch status {
        case .success:  return kind == .build ? "Built" : "Deployed"
        case .failure:  return "Failed"
        case .canceled: return "Canceled"
        case .skipped:  return "Skipped"
        case .building:
            switch stage {
            case "queued":     return "Queued"
            case "initialize", "clone_repo": return "Starting"
            case "deploy":     return "Deploying"
            default:           return "Building"
            }
        }
    }

    /// Dot color: green deployed, amber building, grey canceled/skipped, red failed.
    var stateColor: String {
        switch status {
        case .success:            return "#22C55E"
        case .building:           return "#F5A524"
        case .canceled, .skipped: return "#6B7079"
        case .failure:            return "#F4505E"
        }
    }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

/// A Worker script from GET /workers/scripts: its name, its immutable tag (the Workers Builds
/// "external_script_id") and when it last changed.
struct CloudflareScript: Equatable {
    let name: String
    let tag: String
    let modifiedOn: Date
}

enum CloudflareParse {

    // MARK: Dates

    /// Cloudflare writes dates with 0, 3 or 6 fractional digits; ISO8601DateFormatter
    /// only reads up to 3, so the fraction is dropped before parsing.
    static func date(_ raw: Any?) -> Date? {
        guard var s = raw as? String, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            s.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: s)
    }

    // MARK: Pages

    /// A Pages deployment, e.g. a project's `latest_deployment` or a row of its deployments list.
    static func pagesDeployment(_ d: [String: Any], project: String? = nil) -> CloudflareDeployment? {
        guard let id = d["id"] as? String,
              let name = project ?? (d["project_name"] as? String),
              let created = date(d["created_on"]) else { return nil }
        let stage = d["latest_stage"] as? [String: Any]
        let stageName = stage?["name"] as? String
        let stageStatus = stage?["status"] as? String ?? ""
        let status: CloudflareDeployment.Status
        if d["is_skipped"] as? Bool == true {
            status = .skipped
        } else {
            switch stageStatus {
            case "failure":  status = .failure
            case "canceled": status = .canceled
            case "skipped":  status = .skipped
            // Each stage succeeds in turn: only the last one ("deploy") means it is live.
            case "success":  status = stageName == "deploy" ? .success : .building
            default:         status = .building   // idle, active
            }
        }
        let meta = (d["deployment_trigger"] as? [String: Any])?["metadata"] as? [String: Any]
        return CloudflareDeployment(
            kind: .pages, rawId: id, name: name, status: status, createdAt: created,
            branch: nonEmpty(meta?["branch"]),
            commitMessage: nonEmpty(meta?["commit_message"]),
            url: nonEmpty(d["url"]),
            environment: nonEmpty(d["environment"]),
            stage: stageName)
    }

    /// Pages projects list → each project's latest deployment.
    static func pagesProjects(_ result: [[String: Any]]) -> [CloudflareDeployment] {
        result.compactMap { p in
            guard let name = p["name"] as? String,
                  let latest = p["latest_deployment"] as? [String: Any] else { return nil }
            return pagesDeployment(latest, project: name)
        }
    }

    // MARK: Workers

    static func scripts(_ result: [[String: Any]]) -> [CloudflareScript] {
        result.compactMap { s in
            guard let name = s["id"] as? String, let tag = s["tag"] as? String else { return nil }
            return CloudflareScript(name: name, tag: tag,
                                    modifiedOn: date(s["modified_on"]) ?? .distantPast)
        }
    }

    /// One Workers Builds run of a git-connected Worker.
    static func build(_ b: [String: Any], script: String) -> CloudflareDeployment? {
        guard let id = b["build_uuid"] as? String, let created = date(b["created_on"]) else { return nil }
        let status: CloudflareDeployment.Status
        if (b["status"] as? String) != "stopped" {
            status = .building   // queued, initializing, running
        } else {
            switch b["build_outcome"] as? String {
            case "success":   status = .success
            case "cancelled": status = .canceled
            case "skipped":   status = .skipped
            default:          status = .failure   // fail, terminated
            }
        }
        let meta = b["build_trigger_metadata"] as? [String: Any]
        return CloudflareDeployment(
            kind: .build, rawId: id, name: script, status: status, createdAt: created,
            branch: nonEmpty(meta?["branch"]),
            commitMessage: nonEmpty(meta?["commit_message"]),
            author: nonEmpty(meta?["author"]),
            url: nonEmpty(b["preview_url"]),
            stage: b["status"] as? String)
    }

    /// One deployment of a Worker (a version going live). Always live once listed.
    static func workerDeployment(_ d: [String: Any], script: String) -> CloudflareDeployment? {
        guard let id = d["id"] as? String, let created = date(d["created_on"]) else { return nil }
        let annotations = d["annotations"] as? [String: Any]
        return CloudflareDeployment(
            kind: .worker, rawId: id, name: script, status: .success, createdAt: created,
            commitMessage: nonEmpty(annotations?["workers/message"]),
            author: nonEmpty(d["author_email"]),
            source: nonEmpty(d["source"]))
    }

    // MARK: Logs

    /// Pages logs: result.data[].line
    static func pagesLogLines(_ result: [String: Any]) -> [String] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { $0["line"] as? String }
    }

    /// Workers Builds logs: result.lines is [[timestamp, message]]
    static func buildLogLines(_ result: [String: Any]) -> [String] {
        (result["lines"] as? [[Any]] ?? []).compactMap { pair in pair.first { $0 is String } as? String }
    }

    /// The line that best says why a build failed: the last specific error line,
    /// else the last line of the log. ANSI colors are removed.
    static func failureReason(_ lines: [String]) -> String? {
        let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
        let clean = lines.compactMap { raw -> String? in
            let range = NSRange(raw.startIndex..., in: raw)
            let text = (ansi?.stringByReplacingMatches(in: raw, range: range, withTemplate: "") ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let generic = ["Failed: build command exited", "Failed: error occurred while running",
                       "exited with", "Build failed"]
        let specific = clean.last { line in
            (line.range(of: "error", options: .caseInsensitive) != nil
                || line.range(of: "failed", options: .caseInsensitive) != nil)
                && !generic.contains(where: { line.contains($0) })
        }
        return specific ?? clean.last { line in generic.contains(where: { line.contains($0) }) } ?? clean.last
    }

    // MARK: Merge

    /// The rows of the card, newest first: Pages deployments, plus for each Worker its
    /// builds when it is git-connected, else its deployments (a build already ends in a
    /// deployment: showing both would list every push twice).
    static func merged(pages: [CloudflareDeployment],
                       builds: [String: [CloudflareDeployment]],
                       workerDeployments: [String: [CloudflareDeployment]]) -> [CloudflareDeployment] {
        var rows = pages
        for (script, deps) in workerDeployments {
            if let b = builds[script], !b.isEmpty { rows += b } else { rows += deps }
        }
        for (script, b) in builds where workerDeployments[script] == nil { rows += b }
        return rows.sorted { $0.createdAt > $1.createdAt }
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
