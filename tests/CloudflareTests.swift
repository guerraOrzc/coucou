import Foundation

// Parsing of the Cloudflare API answers (App/CloudflareModels.swift): Pages deployments,
// Workers Builds runs, Worker deployments, failure reasons and the merged card rows.

@main
enum CloudflareTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func pages(stage: String, status: String, skipped: Bool = false) -> [String: Any] {
        [
            "id": "p1", "project_name": "site", "url": "https://abc.site.pages.dev",
            "environment": "production", "created_on": "2026-10-09T12:00:00.123456Z",
            "is_skipped": skipped,
            "latest_stage": ["name": stage, "status": status],
            "deployment_trigger": ["type": "github:push",
                                   "metadata": ["branch": "main", "commit_message": "Fix header\nmore", "commit_hash": "abc"]],
        ]
    }

    static func build(status: String, outcome: String?) -> [String: Any] {
        var b: [String: Any] = [
            "build_uuid": "b1", "status": status, "created_on": "2026-10-09T13:00:00Z",
            "build_trigger_metadata": ["branch": "dev", "commit_message": "Add route", "author": "sam"],
        ]
        if let outcome { b["build_outcome"] = outcome }
        return b
    }

    static func main() {
        print("Dates — 0, 3 or 6 fractional digits")
        check("6 digits", CloudflareParse.date("2026-10-09T12:00:00.123456Z") != nil)
        check("3 digits", CloudflareParse.date("2026-10-09T12:00:00.123Z") != nil)
        check("none", CloudflareParse.date("2026-10-09T12:00:00Z") != nil)
        check("garbage → nil", CloudflareParse.date("yesterday") == nil)
        check("same instant", CloudflareParse.date("2026-10-09T12:00:00.999Z") == CloudflareParse.date("2026-10-09T12:00:00Z"))

        print("Pages — the latest stage decides")
        let live = CloudflareParse.pagesDeployment(pages(stage: "deploy", status: "success"))
        check("deploy success → success", live?.status == .success)
        check("fields", live?.name == "site" && live?.branch == "main" && live?.environment == "production"
              && live?.url == "https://abc.site.pages.dev" && live?.id == "pages:p1")
        check("build success → still building",
              CloudflareParse.pagesDeployment(pages(stage: "build", status: "success"))?.status == .building)
        check("active → building", CloudflareParse.pagesDeployment(pages(stage: "build", status: "active"))?.status == .building)
        check("queued idle → building, label Queued",
              CloudflareParse.pagesDeployment(pages(stage: "queued", status: "idle"))?.statusLabel == "Queued")
        check("failure", CloudflareParse.pagesDeployment(pages(stage: "build", status: "failure"))?.status == .failure)
        check("canceled", CloudflareParse.pagesDeployment(pages(stage: "build", status: "canceled"))?.status == .canceled)
        check("is_skipped → skipped",
              CloudflareParse.pagesDeployment(pages(stage: "deploy", status: "success", skipped: true))?.status == .skipped)
        check("no id → nil", CloudflareParse.pagesDeployment(["project_name": "x"]) == nil)
        let projects = CloudflareParse.pagesProjects([
            ["name": "site", "latest_deployment": pages(stage: "deploy", status: "success")],
            ["name": "empty"],
        ])
        check("projects: one row per project with a deployment", projects.count == 1 && projects[0].name == "site")

        print("Workers scripts")
        let scripts = CloudflareParse.scripts([
            ["id": "api", "tag": "t1", "modified_on": "2026-10-09T10:00:00.5Z"],
            ["id": "no-tag"],
        ])
        check("name + tag, untagged dropped", scripts == [CloudflareScript(name: "api", tag: "t1",
              modifiedOn: CloudflareParse.date("2026-10-09T10:00:00Z")!)])

        print("Workers Builds — status, then outcome")
        check("running → building", CloudflareParse.build(build(status: "running", outcome: nil), script: "api")?.status == .building)
        check("queued → building", CloudflareParse.build(build(status: "queued", outcome: nil), script: "api")?.status == .building)
        let ok = CloudflareParse.build(build(status: "stopped", outcome: "success"), script: "api")
        check("success", ok?.status == .success && ok?.statusLabel == "Built")
        check("fields", ok?.branch == "dev" && ok?.author == "sam" && ok?.commitMessage == "Add route" && ok?.id == "build:b1")
        check("fail → failure", CloudflareParse.build(build(status: "stopped", outcome: "fail"), script: "api")?.status == .failure)
        check("terminated → failure", CloudflareParse.build(build(status: "stopped", outcome: "terminated"), script: "api")?.status == .failure)
        check("cancelled → canceled", CloudflareParse.build(build(status: "stopped", outcome: "cancelled"), script: "api")?.status == .canceled)

        print("Worker deployments")
        let dep = CloudflareParse.workerDeployment([
            "id": "d1", "created_on": "2026-10-09T11:00:00Z", "source": "wrangler",
            "author_email": "sam@example.com", "annotations": ["workers/message": "hotfix"],
        ], script: "api")
        check("live, message, author, source", dep?.status == .success && dep?.commitMessage == "hotfix"
              && dep?.author == "sam@example.com" && dep?.source == "wrangler" && dep?.id == "worker:d1")

        print("Failure reason")
        check("specific error line wins", CloudflareParse.failureReason([
            "Installing", "\u{1B}[31mError: Cannot find module 'x'\u{1B}[0m", "Failed: build command exited with code: 1",
        ]) == "Error: Cannot find module 'x'")
        check("generic line when nothing better",
              CloudflareParse.failureReason(["ok", "Failed: build command exited with code: 1", ""]) == "Failed: build command exited with code: 1")
        check("last line otherwise", CloudflareParse.failureReason(["a", "b"]) == "b")
        check("empty → nil", CloudflareParse.failureReason(["", "  "]) == nil)
        check("Pages log lines", CloudflareParse.pagesLogLines(["data": [["line": "x", "ts": "t"]]]) == ["x"])
        check("Build log lines", CloudflareParse.buildLogLines(["lines": [[1_700_000_000, "hello"]]]) == ["hello"])

        print("Merged rows — builds replace deployments for git-connected Workers")
        let b = CloudflareParse.build(build(status: "stopped", outcome: "success"), script: "api")!
        let cron = CloudflareParse.workerDeployment(["id": "d2", "created_on": "2026-10-09T09:00:00Z"], script: "cron")!
        let rows = CloudflareParse.merged(pages: [live!], builds: ["api": [b]],
                                          workerDeployments: ["api": [dep!], "cron": [cron]])
        check("api shows its build, cron its deployment",
              rows.filter { $0.name == "api" }.map(\.kind) == [.build] && rows.filter { $0.name == "cron" }.map(\.kind) == [.worker])
        check("newest first", rows.map(\.createdAt) == rows.map(\.createdAt).sorted(by: >))

        if failures > 0 { print("\n\(failures) failure(s)"); exit(1) }
        print("\nAll Cloudflare tests passed.")
    }
}
