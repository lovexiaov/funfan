import Foundation

/// 一次 HTTP 往返的结果（只要检查更新用得到的三样东西）。
public struct UpdateHTTPResponse {
    public let statusCode: Int
    /// 键已统一小写，便于 `x-ratelimit-*` 这类头部取值。
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// 网络取数（可注入，单测不联网）。
public typealias UpdateFetcher = (URL) async throws -> UpdateHTTPResponse

/// 检查更新的失败分类。
///
/// 为什么分类而不是一句「检查失败，请稍后再试」：断网、限流、404 的处置完全不同。
/// 限流时让用户「稍后再试」等于没说——得告诉他等多久，否则他会一直点、一直失败。
public enum UpdateFailure: Error, Equatable {
    case network(String)
    case http(status: Int)
    case rateLimited(resetAt: Date?)
    case malformed(String)

    /// 给界面看的一句话。措辞刻意具体：能定位到原因的，就不让用户去猜。
    public var message: String {
        switch self {
        case .network(let detail):
            return "连不上 GitHub（\(detail)）。检查网络或代理后重试。"
        case .http(let status):
            if status == 404 {
                return "找不到发布信息（HTTP 404）：仓库地址可能变了，或还没有公开的 Release。"
            }
            return "GitHub 返回 HTTP \(status)。稍后重试。"
        case .rateLimited(let resetAt):
            let wait = Self.waitText(until: resetAt)
            return "GitHub 暂时拒绝了这个请求（限流），备用通道也没拉通。\(wait)再试。"
        case .malformed(let detail):
            return "发布信息解析失败（\(detail)）。可能是接口格式变了，请反馈。"
        }
    }

    /// 值不值得换备用源再试。
    ///
    /// 只有「这个源本身不可用」才换：额度耗尽（换个不带配额的端点就能通）、
    /// 连不上（域名不同，路由可能不同）。
    /// `http` / `malformed` **不换**——那是源真出问题了，换源只会把问题藏起来，
    /// 让用户看到「已是最新」而不是「检查失败」。
    var warrantsFallback: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .http, .malformed: return false
        }
    }

    private static func waitText(until resetAt: Date?) -> String {
        guard let resetAt else { return "过一会儿" }
        let seconds = resetAt.timeIntervalSinceNow
        guard seconds > 0 else { return "现在可以" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 60 {
            return "约 \((Double(minutes) / 60).rounded(.up)) 小时后".replacingOccurrences(of: ".0", with: "")
        }
        return "约 \(minutes) 分钟后"
    }
}

/// 检查结果。
public enum UpdateOutcome: Equatable {
    case upToDate(current: SemanticVersion)
    case available(ReleaseInfo)
}

/// 检查有没有新版本。
///
/// **两个数据源，谁是主谁是备用是有理由的**（2026-11-11 实测）：
///
/// | 源 | 优点 | 缺点 |
/// |---|---|---|
/// | REST `api.github.com/.../releases` | 字段全、有 dmg 直链、约 1s | 未认证**按 IP** 限 60 次/小时 |
/// | Atom `github.com/.../releases.atom` | 没有配额 | 无附件直链；`github.com` 连通性更差 |
///
/// 用户报的「老提示限流」正是第一行的缺点：额度按 IP 计，共享出口（CGNAT、公司网关、
/// 代理）的人分摊不到 60 次。所以——**REST 为主，只有它额度耗尽或连不上时才换 Atom**。
/// 反过来「干脆全用 Atom」不是修复：会把「限流」换成「连不上」（同一台机器上实测
/// `github.com` 连续 5 次 10 秒超时，而 `api.github.com` 1–2 秒返回）。
///
/// 换源时用户不会看到任何区别，只在界面上少一个 dmg 直链（退回发布页）。
public struct UpdateChecker {

    /// 主源：字段最全，但未认证按 IP 限 60 次/小时。
    public static let primaryFeedURL = URL(
        string: "https://api.github.com/repos/lovexiaov/funfan/releases?per_page=20"
    )!
    /// 备用源：没有配额，代价是拿不到附件地址。
    public static let fallbackFeedURL = URL(
        string: "https://github.com/lovexiaov/funfan/releases.atom"
    )!

    private let fetcher: UpdateFetcher

    public init(fetcher: @escaping UpdateFetcher = UpdateChecker.liveFetcher()) {
        self.fetcher = fetcher
    }

    /// 拉一次并决定「有没有该给这个用户的更新」。
    /// - Parameters:
    ///   - current: 当前运行的版本。
    ///   - skipping: 用户点了「忽略此版本」的那个版本；只影响这一个，不影响更新的版本。
    ///   - didFallBack: 换源时回调主源的失败原因。界面不用它，探针用它——
    ///     「悄悄换源」如果不可观测，排查时只能靠猜。
    public func check(
        current: SemanticVersion,
        skipping: String? = nil,
        didFallBack: ((UpdateFailure) -> Void)? = nil
    ) async throws -> UpdateOutcome {
        do {
            let body = try await load(Self.primaryFeedURL)
            let releases = try ReleaseFeed.decodeJSON(body)
            return Self.select(from: releases, current: current, skipping: skipping)
        } catch let failure as UpdateFailure {
            guard failure.warrantsFallback else { throw failure }
            didFallBack?(failure)
            do {
                let body = try await load(Self.fallbackFeedURL)
                let releases = try ReleaseFeed.decodeAtom(body)
                return Self.select(from: releases, current: current, skipping: skipping)
            } catch {
                // 备用源也挂了就报**主源**的原因：限流才是根因，
                // 把「连不上备用源」报给用户只会让他去查网络。
                throw failure
            }
        }
    }

    /// 取一次并做状态码分类。两个源共用，避免「主源认限流、备用源不认」的分叉。
    private func load(_ url: URL) async throws -> Data {
        let response: UpdateHTTPResponse
        do {
            response = try await fetcher(url)
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.network(error.localizedDescription)
        }

        if let limited = Self.rateLimitedFailure(response) { throw limited }
        guard response.statusCode == 200 else {
            throw UpdateFailure.http(status: response.statusCode)
        }
        return response.body
    }

    private static func rateLimitedFailure(_ response: UpdateHTTPResponse) -> UpdateFailure? {
        guard response.statusCode == 403 || response.statusCode == 429 || response.statusCode == 503 else {
            return nil
        }
        // `retry-after` 比 `x-ratelimit-reset` 更直接（秒数），优先用它。
        if let retry = response.header("retry-after").flatMap(TimeInterval.init) {
            return .rateLimited(resetAt: Date().addingTimeInterval(retry))
        }
        if response.header("x-ratelimit-remaining") == "0" {
            return .rateLimited(resetAt: resetDate(response.header("x-ratelimit-reset")))
        }
        // 429 本身就是「请求太多」，没有头部也按限流处理，别报成普通的 HTTP 错误。
        if response.statusCode == 429 {
            return .rateLimited(resetAt: nil)
        }
        return nil
    }

    /// 从已解析的发布列表里挑一个该推给用户的版本。
    ///
    /// 单独拆出来是为了「用抓下来的真实响应复现选择结果」——探针与单测都走这一条，
    /// 而不是各自抄一遍过滤条件（抄一遍就会分叉：探针说没更新、App 说有）。
    public static func select(
        from releases: [ReleaseInfo],
        current: SemanticVersion,
        skipping: String? = nil
    ) -> UpdateOutcome {
        let candidates = releases
            // 正式版用户不收预发布：他要的是稳定，不是最新。
            .filter { current.isPrerelease || !$0.isPrerelease }
            .filter { $0.version > current }
            .filter { !matchesSkip($0, skipping) }

        guard let best = candidates.max(by: { $0.version < $1.version }) else {
            return .upToDate(current: current)
        }
        return .available(best)
    }

    private static func matchesSkip(_ info: ReleaseInfo, _ skipping: String?) -> Bool {
        guard let skipping, !skipping.isEmpty else { return false }
        if info.tag == skipping { return true }
        if let version = SemanticVersion(parsing: skipping), version == info.version { return true }
        return false
    }

    private static func resetDate(_ raw: String?) -> Date? {
        guard let raw, let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - 线上实现

    /// 真实的 `URLSession` 取数。
    ///
    /// 几个刻意的参数：
    /// - `timeoutInterval = 10`：检查更新是「顺手一做」的事，不能让面板感觉卡住；
    /// - `reloadIgnoringLocalCacheData`：限流响应带上缓存就永远读到旧结论；
    /// - `User-Agent`：GitHub 对没有 UA 的请求更严格，也方便对方认出流量来源。
    public static func liveFetcher(session: URLSession = .shared) -> UpdateFetcher {
        { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            // 同一个 URL 可能被当 JSON 也可能被当 Atom（`.atom` 后缀），
            // 用通配 Accept 让服务器自己决定。
            request.setValue("application/atom+xml, application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("FunFan-UpdateCheck", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateFailure.network("响应不是 HTTP")
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return UpdateHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        }
    }
}
