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
/// 注意这些是**内部诊断**，只有两个源都给不出结论时才会变成界面上的一句话。
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
            // 不再说「限流」：额度按出口 IP 计，共享出口的人第一次点就可能撞上
            // 别人用光的额度。让他去等那个窗口，等于让他替别人背锅。
            let wait = Self.waitText(until: resetAt)
            return "暂时没能从 GitHub 取到发布信息（两个通道都没通）。\(wait)再试。"
        case .malformed(let detail):
            return "发布信息解析失败（\(detail)）。可能是接口格式变了，请反馈。"
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

/// 一次检查里两个源各自的结果（成功时记条目数）。
///
/// 「REST 限流但 Atom 成功」是**正常结果**，界面不会有任何提示；
/// 如果连这个也不可观测，排查「为什么没拿到 dmg 直链」就只能靠猜。
/// 探针与单测用，App 不传回调。
public struct UpdateSourceReport: Equatable {
    public let atom: Result<Int, UpdateFailure>
    public let rest: Result<Int, UpdateFailure>

    public init(atom: Result<Int, UpdateFailure>, rest: Result<Int, UpdateFailure>) {
        self.atom = atom
        self.rest = rest
    }
}

/// 检查结果。
public enum UpdateOutcome: Equatable {
    case upToDate(current: SemanticVersion)
    case available(ReleaseInfo)
}

/// 检查有没有新版本。
///
/// **两个源并行、地位平等**（2026-11-11 二次实测，同机／本地代理后）：
///
/// | 源 | 角色 | 优点 | 缺点 |
/// |---|---|---|---|
/// | Atom `github.com/.../releases.atom` | 结论源 | **无配额**；连续 5 次 200，0.92–1.34s | 无附件地址；会列已删 release 的 ghost tag |
/// | REST `api.github.com/.../releases` | 增强源 | 字段全、有 dmg 直链、无 ghost | 未认证**按出口 IP** 限 60 次/小时，1.69–3.79s |
///
/// 上一版把「Atom 连续 5 次 10 秒超时」当成依据，让有配额的 REST 成了必经路径，
/// 于是共享出口（代理 / CGNAT / 公司网关）的用户**第一次点检查就看到「限流」**——
/// 额度是被同一出口的其他人耗光的，跟他点了几次毫无关系。那个观测只是当时的
/// 临时网络状况，重复实测已证伪。
///
/// 现在的原则：**只要有一个源给出可信列表，这次检查就成功**。
/// REST 限流最多让用户少一个 dmg 直链（退回发布页），绝不能变成一次失败。
/// 两个都成功时以 REST 为准（字段全、不含 ghost 条目）。
public struct UpdateChecker {

    /// 结论源：网页订阅，没有 REST 那套按 IP 计的配额。
    public static let atomFeedURL = URL(
        string: "https://github.com/lovexiaov/funfan/releases.atom"
    )!
    /// 增强源：字段最全，但未认证按 IP 限 60 次/小时。
    public static let restFeedURL = URL(
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
    ///   - report: 两个源各自的结果。界面不用它，探针与单测用它——
    ///     「悄悄降级」如果不可观测，排查时只能靠猜。
    public func check(
        current: SemanticVersion,
        skipping: String? = nil,
        report: ((UpdateSourceReport) -> Void)? = nil
    ) async throws -> UpdateOutcome {
        // 并行：一个源被拦 / 超时，另一个的结果照样能用，不必串行等满 10 秒。
        async let atom = self.load(Self.atomFeedURL, decode: ReleaseFeed.decodeAtom)
        async let rest = self.load(Self.restFeedURL, decode: ReleaseFeed.decodeJSON)
        let (atomResult, restResult) = await (atom, rest)

        report?(UpdateSourceReport(
            atom: atomResult.map { $0.count },
            rest: restResult.map { $0.count }
        ))

        let releases: [ReleaseInfo]
        switch (restResult, atomResult) {
        case (.success(let fromREST), _):
            // 字段全、有直链、没有 ghost 条目。
            releases = fromREST
        case (.failure, .success(let fromAtom)):
            // 包括 REST 被限流：用户照常看到更新，只是下载退回发布页。
            releases = fromAtom
        case (.failure, .failure(let atomFailure)):
            // 两个都给不出结论才报错。报**结论源**的原因：REST 的限流是共享
            // 出口 IP 的事，让用户去等那个窗口没有意义。
            throw atomFailure
        }

        return Self.select(from: releases, current: current, skipping: skipping)
    }

    /// 取一个源并解析，失败也当成值返回——并行检查里「一个源挂了」不是异常。
    private func load(
        _ url: URL,
        decode: (Data) throws -> [ReleaseInfo]
    ) async -> Result<[ReleaseInfo], UpdateFailure> {
        do {
            let body = try await fetchBody(url)
            return .success(try decode(body))
        } catch let failure as UpdateFailure {
            return .failure(failure)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 取一次并做状态码分类。两个源共用，避免「一个源认限流、另一个不认」的分叉。
    private func fetchBody(_ url: URL) async throws -> Data {
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
        // 503 不在这里：那是网关 / 服务暂时不可用，不是 GitHub 的额度耗尽。
        // 带 `retry-after` 的 503 若被判成限流，用户会去等一个不存在的额度窗口。
        guard response.statusCode == 403 || response.statusCode == 429 else {
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
    /// - `User-Agent`：GitHub 对没有 UA 的请求更严格，也方便对方认出流量来源；
    /// - 按端点给 `Accept`：REST 认 `vnd.github+json`，Atom 认 `atom+xml`，
    ///   不给 REST 发一个以 `atom+xml` 打头的通配头，免得中间层挑错表示。
    public static func liveFetcher(session: URLSession = .shared) -> UpdateFetcher {
        { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let isAtom = url.absoluteString.hasSuffix(".atom")
            request.setValue(
                isAtom ? "application/atom+xml" : "application/vnd.github+json",
                forHTTPHeaderField: "Accept"
            )
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
