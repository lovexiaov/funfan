import XCTest
@testable import FunFanCore

/// 更新检查：两个源并行取数，只要有一个给出可信结果，就能回答「有没有更新」。
///
/// 2026-11-11 二次实测（同机，走本地代理 `127.0.0.1:2333`）：
/// - Atom `github.com/.../releases.atom`：**没有配额**，连续 5 次 200，0.92–1.34s；
/// - REST `api.github.com/.../releases`：字段最全（dmg 直链），1.69–3.79s，
///   但未认证**按出口 IP** 限 60 次/小时。共享出口（代理 / CGNAT / 公司网关）的
///   人第一次点就可能撞上别人用光的额度。
///
/// 上一版把「Atom 连续 5 次 10 秒超时」当成依据，让有配额的 REST 成了必经路径，
/// 于是用户第一次检查就看到「限流」。那个观测只是当时的临时网络状况，现已证伪。
/// 现在两个源并行、地位平等：**REST 限流最多让用户少一个 dmg 直链，
/// 绝不能变成一次失败的检查**。下面每条断言都对应一个真实会出错的判断。
final class UpdateCheckTests: XCTestCase {

    // MARK: - 夹具

    // REST（增强源：有 dmg 直链，但有配额）

    private func releaseJSON(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = true,
        publishedAt: String = "2026-11-01T00:00:00Z",
        assets: [(String, String)] = [("FunFan.dmg", "https://example.com/a.dmg")],
        name: String? = nil
    ) -> String {
        let assetJSON = assets.map { (name, url) in
            #"{"name":"\#(name)","browser_download_url":"\#(url)"}"#
        }.joined(separator: ",")
        let nameField = name.map { #""name":"\#($0)","# } ?? ""
        return """
        {
          "tag_name":"\(tag)",
          \(nameField)
          "draft":\(draft),
          "prerelease":\(prerelease),
          "published_at":"\(publishedAt)",
          "html_url":"https://github.com/lovexiaov/funfan/releases/tag/\(tag)",
          "body":"改动说明 \(tag)",
          "assets":[\(assetJSON)]
        }
        """
    }

    private func jsonFeed(_ releases: String...) -> Data {
        Data("[\(releases.joined(separator: ","))]".utf8)
    }

    // Atom（结论源：无配额）

    private func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func entry(
        tag: String,
        title: String? = nil,
        updated: String = "2026-11-01T00:00:00Z",
        contentHTML: String = "<p>改动说明</p>",
        link: String? = nil
    ) -> String {
        let href = link ?? "https://github.com/lovexiaov/funfan/releases/tag/\(tag)"
        // 标题默认故意比 tag 少一个 `v` 前缀：真实 feed 就是这样（alpha.8 的标题
        // 是「FunFan 1.0.0-alpha.8」，alpha.7 的却是「v1.0.0-alpha.7」）。
        // 谁把标题当版本号解析，这里立刻会挂。
        let displayTitle = title ?? "FunFan \(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)"
        return """
          <entry>
            <id>tag:github.com,2008:Repository/1439946107/\(tag)</id>
            <updated>\(updated)</updated>
            <link rel="alternate" type="text/html" href="\(href)"/>
            <title>\(displayTitle)</title>
            <content type="html">\(escape(contentHTML))</content>
          </entry>
        """
    }

    private func atomFeed(_ entries: String...) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
          <id>tag:github.com,2008:https://github.com/lovexiaov/funfan/releases</id>
          <title>Release notes from funfan</title>
          <updated>2026-11-10T16:26:49Z</updated>
        \(entries.joined(separator: "\n"))
        </feed>
        """.utf8)
    }

    // 传输层

    private func response(_ body: Data, status: Int = 200, headers: [String: String] = [:]) -> UpdateHTTPResponse {
        UpdateHTTPResponse(statusCode: status, headers: headers, body: body)
    }

    private var quotaExhausted: UpdateHTTPResponse {
        response(
            Data(#"{"message":"API rate limit exceeded"}"#.utf8),
            status: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"]
        )
    }

    /// 按 URL 分发：REST 给 `rest`，Atom 给 `atom`。
    /// 未指定的源默认 404 —— 需要「两个源都挂」的测试会显式给全，避免靠默认值猜。
    private func checker(rest: UpdateHTTPResponse? = nil, atom: UpdateHTTPResponse? = nil) -> UpdateChecker {
        UpdateChecker(fetcher: { url in
            let fallback: UpdateHTTPResponse = .init(statusCode: 404, body: Data())
            return url.absoluteString.contains(".atom") ? (atom ?? fallback) : (rest ?? fallback)
        })
    }

    private func v(_ raw: String) -> SemanticVersion {
        SemanticVersion(parsing: raw)!
    }

    // MARK: - 端点选择

    /// REST 用**发布列表**，不是 `releases/latest`。
    ///
    /// `latest` 只返回「非预发布、非草稿」的最新版：本项目所有版本都带 `-alpha`，
    /// 匿名请求它得到 404，更新检查会永远报「找不到发布信息」。这个坑实测过。
    func testRESTFeedIsReleaseListNotLatest() {
        let url = UpdateChecker.restFeedURL.absoluteString
        XCTAssertEqual(url, "https://api.github.com/repos/lovexiaov/funfan/releases?per_page=20")
        XCTAssertFalse(url.contains("/latest"))
    }

    func testAtomFeedIsSubscription() {
        XCTAssertEqual(
            UpdateChecker.atomFeedURL.absoluteString,
            "https://github.com/lovexiaov/funfan/releases.atom"
        )
    }

    // MARK: - 选择逻辑（两个源都成功时以 REST 为准）

    func testUpToDateWhenNoNewerRelease() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.6"),
            releaseJSON(tag: "v1.0.0-alpha.5")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.7")))
    }

    func testFindsNewerPrereleaseForPrereleaseUser() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.6"),
            releaseJSON(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现 alpha.7，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.7"))
        XCTAssertEqual(info.tag, "v1.0.0-alpha.7")
    }

    /// 草稿只有 maintainer 能看见，绝不能推给用户。
    func testIgnoresDraftReleases() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.9", draft: true),
            releaseJSON(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现 alpha.7（alpha.9 是草稿），实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.7"))
    }

    /// 用着正式版的用户不该被推向 alpha：他要的是稳定。
    func testStableUserDoesNotGetPrerelease() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.1.0-beta.1")
        )))
        let outcome = try await c.check(current: v("1.0.0"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0")))
    }

    /// 预发布用户遇到已发布的正式版要能收到——否则 alpha 用户永远升不到正式版。
    func testPrereleaseUserGetsNewerStable() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0", prerelease: false),
            releaseJSON(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现正式版 1.0.0，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0"))
    }

    /// 列表顺序不可信（按发布时间排序，而发布时间和版本号不一定同序）。
    func testPicksHighestVersionNotNewestPublished() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.10", publishedAt: "2026-11-01T00:00:00Z"),
            releaseJSON(tag: "v1.0.0-alpha.9", publishedAt: "2026-11-09T00:00:00Z")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当选 alpha.10，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.10"))
    }

    // MARK: - 忽略某个版本

    func testSkippedVersionIsNotOffered() async throws {
        let c = checker(rest: response(jsonFeed(releaseJSON(tag: "v1.0.0-alpha.7"))))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"), skipping: "1.0.0-alpha.7")
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.6")))
    }

    /// 忽略「这一个」不等于忽略以后所有版本：更新的一出来还得出提示。
    func testSkippedVersionDoesNotHideNewerOnes() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.7"),
            releaseJSON(tag: "v1.0.0-alpha.8")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"), skipping: "1.0.0-alpha.7")
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现 alpha.8，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.8"))
    }

    // MARK: - 两个源的协作（本次修复的核心）

    /// **用户报的问题**：出口 IP 额度被别人用光，第一次点检查就看到「限流」。
    /// 现在 REST 限流只能让结果少一个 dmg 直链，Atom 照样给出结论。
    func testQuotaExhaustionNeverReachesUserWhenAtomWorks() async throws {
        let c = checker(
            rest: quotaExhausted,
            atom: response(atomFeed(entry(tag: "v1.0.0-alpha.9")))
        )
        var captured: UpdateSourceReport?
        let outcome = try await c.check(current: v("1.0.0-alpha.8"), report: { captured = $0 })
        guard case .available(let info) = outcome else {
            return XCTFail("额度耗尽时也应照常看到 alpha.9，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
        // 「悄悄降级」必须可观测，否则排查时只能靠猜。
        guard case .failure(let restFailure) = captured?.rest else {
            return XCTFail("诊断里应记下 REST 的失败：\(String(describing: captured))")
        }
        guard case .rateLimited = restFailure else {
            return XCTFail("REST 的失败应归类为限流，实际：\(restFailure)")
        }
        guard case .success(let atomCount) = captured?.atom else {
            return XCTFail("诊断里应记下 Atom 成功：\(String(describing: captured))")
        }
        XCTAssertEqual(atomCount, 1)
    }

    /// REST 的失败**任何一类**都不该让用户看到错误：只要 Atom 通，就有可信结论。
    /// 上一版只放行 `rateLimited` / `network`，`http` / `malformed` 会直接报错——
    /// 那是把「一个源坏了」误当成「检查不了」。
    func testAnyRESTFailureIsAbsorbedWhenAtomSucceeds() async throws {
        let failures: [UpdateHTTPResponse] = [
            quotaExhausted,
            response(Data("boom".utf8), status: 500),
            response(Data(#"{"message":"Not Found"}"#.utf8)),
            response(Data("blocked".utf8), status: 403, headers: ["retry-after": "60"]),
        ]
        for failure in failures {
            let c = checker(rest: failure, atom: response(atomFeed(entry(tag: "v1.0.0-alpha.9"))))
            let outcome = try await c.check(current: v("1.0.0-alpha.8"))
            guard case .available(let info) = outcome else {
                return XCTFail("REST 失败时应由 Atom 给出结论，实际：\(outcome)")
            }
            XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
            XCTAssertNil(info.downloadURL, "REST 没成功就不该有直链")
        }
    }

    /// 反过来也成立：Atom 被拦（超时 / 代理登录页）时，REST 仍能给出结论。
    func testAtomFailureFallsBackToREST() async throws {
        let c = checker(
            rest: response(jsonFeed(releaseJSON(tag: "v1.0.0-alpha.9"))),
            atom: response(Data("<html>blocked</html>".utf8))
        )
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else {
            return XCTFail("Atom 挂了应由 REST 给出结论，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
        XCTAssertEqual(info.targetURL?.absoluteString, "https://example.com/a.dmg")
    }

    /// 两个源都成功时以 REST 为准：字段全、无 ghost 条目、有直链。
    func testRESTResultWinsWhenBothSourcesSucceed() async throws {
        let c = checker(
            rest: response(jsonFeed(releaseJSON(tag: "v1.0.0-alpha.9"))),
            atom: response(atomFeed(entry(tag: "v1.0.0-alpha.8")))
        )
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else {
            return XCTFail("应采用 REST 的 alpha.9，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
        XCTAssertEqual(info.targetURL?.absoluteString, "https://example.com/a.dmg")
    }

    /// 两个源都挂才报错，且报**结论源（Atom）**的原因。
    /// REST 的限流是共享出口 IP 的事，让用户去等那个窗口没有意义。
    func testBothSourcesFailReportsAtomFailureNotQuota() async throws {
        let c = checker(rest: quotaExhausted, atom: response(Data("<html>".utf8), status: 500))
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("两个源都挂应当报错")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure, .http(status: 500))
        }
    }

    /// Atom 返回的是代理登录页而不是订阅：绝不能当成「已是最新」。
    func testNonAtomBodyIsNeverHiddenAsUpToDate() async throws {
        let c = checker(rest: quotaExhausted, atom: response(Data("<html>blocked</html>".utf8)))
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("两个源都不可用应当报错")
        } catch let failure as UpdateFailure {
            guard case .malformed = failure else {
                return XCTFail("应当是 malformed，实际：\(failure)")
            }
        }
    }

    /// REST 格式坏了但 Atom 正常：不该报错，Atom 就是可信结论。
    func testRESTMalformedBodyDoesNotBreakCheck() async throws {
        let c = checker(
            rest: response(Data(#"{"message":"Not Found"}"#.utf8)),
            atom: response(atomFeed(entry(tag: "v1.0.0-alpha.9")))
        )
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当用 Atom 的结果，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
    }

    // MARK: - 下载目标

    /// 有 `.dmg` 就用直链：少一次点击。
    func testPrefersDMGAssetFromRESTSource() async throws {
        let c = checker(rest: response(jsonFeed(
            releaseJSON(tag: "v1.0.0-alpha.7", assets: [
                ("FunFan-1.0.0-alpha.7.zip", "https://example.com/a.zip"),
                ("SHA256SUMS.txt", "https://example.com/sums.txt"),
                ("FunFan-1.0.0-alpha.7.dmg", "https://example.com/a.dmg"),
            ])
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertEqual(info.targetURL?.absoluteString, "https://example.com/a.dmg")
    }

    /// Atom 没有附件地址，只能退回发布页——**绝不能去拼 dmg 文件名猜 URL**，
    /// 猜错就是 404。
    func testAtomSourceLinksToReleasePage() async throws {
        let c = checker(rest: quotaExhausted, atom: response(atomFeed(entry(tag: "v1.0.0-alpha.9"))))
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertNil(info.downloadURL)
        XCTAssertEqual(
            info.targetURL?.absoluteString,
            "https://github.com/lovexiaov/funfan/releases/tag/v1.0.0-alpha.9"
        )
    }

    // MARK: - Atom 解析

    /// 版本号必须从链接里取，不能从标题取。
    ///
    /// 真实 feed 里 alpha.8 的标题是「FunFan 1.0.0-alpha.8」、alpha.7 的是
    /// 「v1.0.0-alpha.7」——标题是人手写的发布名，格式随时会变。
    func testAtomTagComesFromLinkNotTitle() async throws {
        let c = checker(
            rest: quotaExhausted,
            atom: response(atomFeed(entry(tag: "v1.0.0-alpha.8", title: "随便写的标题 · 第 8 版")))
        )
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        guard case .available(let info) = outcome else {
            return XCTFail("标题再乱也不该影响版本判断，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.8"))
        XCTAssertEqual(info.tag, "v1.0.0-alpha.8")
    }

    /// 链接丢了还能从 `<id>` 里捞回 tag：`tag:github.com,2008:Repository/ID/v1.2.3`。
    func testAtomTagFallsBackToEntryID() async throws {
        let c = checker(rest: quotaExhausted, atom: response(atomFeed(entry(tag: "v1.0.0-alpha.9", link: ""))))
        let outcome = try await c.check(current: v("1.0.0-alpha.8"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当从 id 里解析出 alpha.9，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.9"))
    }

    /// Atom 没有 `prerelease` 字段，只能看版本号后缀——不能看标题里有没有 alpha。
    func testAtomInfersPrereleaseFromVersion() async throws {
        let c = checker(rest: quotaExhausted, atom: response(atomFeed(
            entry(tag: "v1.1.0-beta.1", title: "FunFan 1.1.0 beta")
        )))
        let outcome = try await c.check(current: v("1.0.0"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0")), "正式版用户不该收到 beta")
    }

    /// 正文是转义过的 HTML，界面上要的是纯文本。
    func testAtomNotesArePlainText() async throws {
        let html = """
        <h3>⚠️ 安装</h3>
        <ol><li>下载 <code>FunFan-1.0.0-alpha.8.dmg</code></li>
        <li>拖进「应用程序」 &amp; 卸载镜像</li></ol>
        """
        let c = checker(rest: quotaExhausted, atom: response(atomFeed(entry(tag: "v1.0.0-alpha.8", contentHTML: html))))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertFalse(info.notes.contains("<"), "正文里不该残留标签：\(info.notes)")
        XCTAssertTrue(info.notes.contains("安装"), info.notes)
        XCTAssertTrue(info.notes.contains("FunFan-1.0.0-alpha.8.dmg"), info.notes)
        XCTAssertTrue(info.notes.contains("&"), "实体要解码：\(info.notes)")
        XCTAssertFalse(info.notes.contains("&amp;"), info.notes)
    }

    func testAtomParsesPublishDate() async throws {
        let c = checker(
            rest: quotaExhausted,
            atom: response(atomFeed(entry(tag: "v1.0.0-alpha.8", updated: "2026-11-10T16:31:35Z")))
        )
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertEqual(info.publishedAt?.timeIntervalSince1970, 1_794_328_295)
    }

    /// 个别条目坏掉不能让整次检查失败：用户只是想知道有没有新版。
    func testAtomSkipsEntriesWithUnparsableTag() async throws {
        let c = checker(rest: quotaExhausted, atom: response(atomFeed(
            entry(tag: "nightly"),
            entry(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else {
            return XCTFail("坏条目应被跳过，好条目仍要生效，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.7"))
    }

    // MARK: - 宽容解析与失败分类

    func testEmptyRESTListIsUpToDate() async throws {
        let c = checker(rest: response(Data("[]".utf8)))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.7")))
    }

    /// 合法的空 feed（仓库还没发过版）是「已是最新」，不是错误。
    func testEmptyAtomFeedIsUpToDate() async throws {
        let c = checker(rest: quotaExhausted, atom: response(atomFeed()))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.7")))
    }

    /// 两个源都被限流时仍要给出等待时间，不能只说「稍后再试」。
    func testRateLimitIsReportedWithResetDate() async throws {
        let reset = 1_800_000_000
        let limited = response(
            Data("slow down".utf8),
            status: 429,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]
        )
        let c = checker(rest: limited, atom: limited)
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("应当报限流")
        } catch let failure as UpdateFailure {
            guard case .rateLimited(let resetAt) = failure else {
                return XCTFail("应当是 rateLimited，实际：\(failure)")
            }
            XCTAssertEqual(resetAt?.timeIntervalSince1970, Double(reset))
        }
    }

    /// 503 是「服务/网关暂时不可用」，不是 GitHub 的额度耗尽。
    /// 带 `retry-after` 也不能误判成限流，否则用户会去等一个不存在的额度窗口。
    func testServiceUnavailableIsNotMisclassifiedAsQuota() async throws {
        let unavailable = response(Data("upstream error".utf8), status: 503, headers: ["retry-after": "30"])
        let c = checker(rest: unavailable, atom: unavailable)
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("应当报 HTTP 错误")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure, .http(status: 503))
        }
    }

    func testHTTPErrorIsReportedWithStatus() async throws {
        let c = checker(
            rest: response(Data("oops".utf8), status: 500),
            atom: response(Data("oops".utf8), status: 500)
        )
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("应当报 HTTP 错误")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure, .http(status: 500))
        }
    }

    func testTransportErrorBecomesNetworkFailure() async throws {
        let c = UpdateChecker(fetcher: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("应当报网络错误")
        } catch let failure as UpdateFailure {
            guard case .network = failure else {
                return XCTFail("应当是 network，实际：\(failure)")
            }
        }
    }
}
