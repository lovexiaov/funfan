import XCTest
@testable import FunFanCore

/// 更新检查：从 GitHub 的发布列表里挑出「该推给这个用户的那一个」。
///
/// 这里的每条断言都对应一个真实会出错的判断：
/// - 草稿（draft）不能推（我们自己发版时看到的草稿，用户看不到）；
/// - 预发布（prerelease）不能推给正式版用户；
/// - 版本号带 `v`、缺补丁位、日期乱序都要能扛；
/// - 接口失败必须**分类报错**，不能笼统说「检查失败，请稍后再试」——
///   限流和断网的处置完全不同（等 40 分钟 vs 检查网络）。
final class UpdateCheckTests: XCTestCase {

    // MARK: - 夹具

    private func releaseJSON(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = true,
        publishedAt: String = "2026-11-01T00:00:00Z",
        assets: [(String, String)] = [("FunFan.dmg", "https://example.com/a.dmg")],
        name: String? = nil
    ) -> String {
        let assetJSON = assets.map { (name, url) in
            """
            {"name":"\(name)","browser_download_url":"\(url)"}
            """
        }.joined(separator: ",")
        let nameField = name.map { "\"name\":\"\($0)\"," } ?? ""
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

    private func feed(_ releases: String...) -> Data {
        Data("[\(releases.joined(separator: ","))]".utf8)
    }

    private func response(_ body: Data, status: Int = 200, headers: [String: String] = [:]) -> UpdateHTTPResponse {
        UpdateHTTPResponse(statusCode: status, headers: headers, body: body)
    }

    private func checker(_ response: UpdateHTTPResponse) -> UpdateChecker {
        UpdateChecker(fetcher: { _ in response })
    }

    private func v(_ raw: String) -> SemanticVersion {
        SemanticVersion(parsing: raw)!
    }

    // MARK: - 端点选择

    /// 固定钉住用「发布列表」而不是 `releases/latest`。
    ///
    /// `releases/latest` **只返回非预发布的最新版**：本项目所有版本都带 `-alpha`，
    /// 匿名请求它得到的是 404，更新检查会永远报「找不到发布列表」。
    /// 这个坑用一次真机请求验证过（2026-11-11），所以写成断言钉在这里。
    func testDefaultFeedURLUsesReleaseListNotLatest() {
        let url = UpdateChecker.defaultFeedURL.absoluteString
        XCTAssertEqual(url, "https://api.github.com/repos/lovexiaov/funfan/releases?per_page=20")
        XCTAssertFalse(url.contains("/latest"))
    }

    // MARK: - 选择逻辑

    func testUpToDateWhenNoNewerRelease() async throws {
        let c = checker(response(feed(
            releaseJSON(tag: "v1.0.0-alpha.6"),
            releaseJSON(tag: "v1.0.0-alpha.5")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.7")))
    }

    func testFindsNewerPrereleaseForPrereleaseUser() async throws {
        let c = checker(response(feed(
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
        let c = checker(response(feed(
            releaseJSON(tag: "v1.0.0-alpha.9", draft: true),
            releaseJSON(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现 alpha.7（alpha.9 是草稿），实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.7"))
    }

    /// 用着正式版的用户不该被推向 beta：他要的是稳定。
    func testStableUserDoesNotGetPrerelease() async throws {
        let c = checker(response(feed(
            releaseJSON(tag: "v1.1.0-beta.1", prerelease: true)
        )))
        let outcome = try await c.check(current: v("1.0.0"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0")))
    }

    /// 预发布用户遇到已发布的正式版要能收到——否则 alpha 用户永远升不到正式版。
    func testPrereleaseUserGetsNewerStable() async throws {
        let c = checker(response(feed(
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
        let c = checker(response(feed(
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
        let c = checker(response(feed(
            releaseJSON(tag: "v1.0.0-alpha.7")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"), skipping: "1.0.0-alpha.7")
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.6")))
    }

    /// 忽略「这一个」不等于忽略以后所有版本：更新的一出来还得出提示。
    func testSkippedVersionDoesNotHideNewerOnes() async throws {
        let c = checker(response(feed(
            releaseJSON(tag: "v1.0.0-alpha.7"),
            releaseJSON(tag: "v1.0.0-alpha.8")
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"), skipping: "1.0.0-alpha.7")
        guard case .available(let info) = outcome else {
            return XCTFail("应当发现 alpha.8，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.8"))
    }

    // MARK: - 附件

    /// 优先给 `.dmg`（人工下载用），别把用户丢到 `.zip` 或整页 release 上。
    func testPrefersDMGAsset() async throws {
        let c = checker(response(feed(
            releaseJSON(
                tag: "v1.0.0-alpha.7",
                assets: [
                    ("FunFan-1.0.0-alpha.7.zip", "https://example.com/a.zip"),
                    ("SHA256SUMS.txt", "https://example.com/sums.txt"),
                    ("FunFan-1.0.0-alpha.7.dmg", "https://example.com/a.dmg"),
                ]
            )
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertEqual(info.downloadURL?.absoluteString, "https://example.com/a.dmg")
    }

    /// 没有 dmg 时退回 release 页面，而不是「有更新但点不动」。
    func testFallsBackToReleasePage() async throws {
        let c = checker(response(feed(
            releaseJSON(tag: "v1.0.0-alpha.7", assets: [("FunFan.zip", "https://example.com/a.zip")])
        )))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else { return XCTFail("应当有新版本") }
        XCTAssertEqual(
            info.downloadURL?.absoluteString,
            "https://github.com/lovexiaov/funfan/releases/tag/v1.0.0-alpha.7"
        )
    }

    // MARK: - 宽容解析

    /// 个别条目坏掉不能让整次检查失败：用户只是想知道有没有新版。
    func testSkipsMalformedEntries() async throws {
        let broken = """
        {"tag_name":"not-a-version","draft":false,"prerelease":true,"assets":[]}
        """
        let missingTag = """
        {"draft":false,"prerelease":true,"assets":[]}
        """
        let c = checker(response(Data("[\(broken),\(missingTag),\(releaseJSON(tag: "v1.0.0-alpha.7"))]".utf8)))
        let outcome = try await c.check(current: v("1.0.0-alpha.6"))
        guard case .available(let info) = outcome else {
            return XCTFail("坏条目应被跳过，好条目仍要生效，实际：\(outcome)")
        }
        XCTAssertEqual(info.version, v("1.0.0-alpha.7"))
    }

    func testMalformedTopLevelIsReported() async throws {
        let c = checker(response(Data("{\"message\":\"Not Found\"}".utf8)))
        do {
            _ = try await c.check(current: v("1.0.0-alpha.7"))
            XCTFail("非数组应当报错")
        } catch let failure as UpdateFailure {
            guard case .malformed = failure else {
                return XCTFail("应当是 malformed，实际：\(failure)")
            }
        }
    }

    func testEmptyListIsUpToDate() async throws {
        let c = checker(response(Data("[]".utf8)))
        let outcome = try await c.check(current: v("1.0.0-alpha.7"))
        XCTAssertEqual(outcome, .upToDate(current: v("1.0.0-alpha.7")))
    }

    // MARK: - 失败分类

    /// 限流要说清「等多久」，否则用户只会反复点、反复失败。
    func testRateLimitIsReportedWithResetDate() async throws {
        let reset = 1_800_000_000
        let c = checker(response(
            Data("{\"message\":\"API rate limit exceeded\"}".utf8),
            status: 403,
            headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "\(reset)",
            ]
        ))
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

    func testHTTPErrorIsReportedWithStatus() async throws {
        let c = checker(response(Data("oops".utf8), status: 500))
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
