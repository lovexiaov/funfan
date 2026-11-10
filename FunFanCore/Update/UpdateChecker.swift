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
/// GitHub 未认证接口按 IP 限 60 次/小时，撞上限流时让用户「稍后再试」等于没说——
/// 得告诉他等多久，否则他会一直点、一直失败，然后以为功能坏了。
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
                return "找不到发布列表（HTTP 404）：仓库地址可能变了，或该仓库没有公开的 Release。"
            }
            return "GitHub 返回 HTTP \(status)。稍后重试。"
        case .rateLimited(let resetAt):
            let wait = Self.waitText(until: resetAt)
            return "GitHub 接口限流了（未认证请求每小时 60 次，按 IP 计）。\(wait)再试。"
        case .malformed(let detail):
            return "发布列表解析失败（\(detail)）。可能是接口格式变了，请反馈。"
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
/// 端点用**发布列表**而不是 `releases/latest`：后者只返回「非预发布、非草稿」的
/// 最新版，而本项目所有版本都带 `-alpha`，匿名请求它直接 404（2026-11-11 实测），
/// 那样更新检查会永远报「找不到发布列表」。列表接口返回全部已发布项，
/// 预发布过滤由我们自己按「当前版本是不是预发布」来判。
public struct UpdateChecker {

    public static let defaultFeedURL = URL(
        string: "https://api.github.com/repos/lovexiaov/funfan/releases?per_page=20"
    )!

    private let fetcher: UpdateFetcher

    public init(fetcher: @escaping UpdateFetcher = UpdateChecker.liveFetcher()) {
        self.fetcher = fetcher
    }

    /// 拉一次并决定「有没有该给这个用户的更新」。
    /// - Parameters:
    ///   - current: 当前运行的版本。
    ///   - skipping: 用户点了「忽略此版本」的那个版本；只影响这一个，不影响更新的版本。
    public func check(current: SemanticVersion, skipping: String? = nil) async throws -> UpdateOutcome {
        let response: UpdateHTTPResponse
        do {
            response = try await fetcher(Self.defaultFeedURL)
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            throw UpdateFailure.network(error.localizedDescription)
        }

        if response.statusCode == 403 || response.statusCode == 429 {
            if response.header("x-ratelimit-remaining") == "0" {
                throw UpdateFailure.rateLimited(resetAt: Self.resetDate(response.header("x-ratelimit-reset")))
            }
        }
        guard response.statusCode == 200 else {
            throw UpdateFailure.http(status: response.statusCode)
        }

        let releases = try ReleaseFeed.decode(response.body)
        return Self.select(from: releases, current: current, skipping: skipping)
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
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
