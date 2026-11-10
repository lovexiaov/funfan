import Foundation

/// 发布列表里的一个附件（dmg / zip / 校验和）。
public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL?

    public init(name: String, downloadURL: URL?) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

/// 一条 GitHub Release 里我们真正会用到的字段。
public struct ReleaseInfo: Equatable {
    public let tag: String
    public let version: SemanticVersion
    public let name: String?
    public let isPrerelease: Bool
    public let publishedAt: Date?
    public let pageURL: URL?
    public let notes: String
    public let assets: [ReleaseAsset]

    public init(
        tag: String,
        version: SemanticVersion,
        name: String?,
        isPrerelease: Bool,
        publishedAt: Date?,
        pageURL: URL?,
        notes: String,
        assets: [ReleaseAsset]
    ) {
        self.tag = tag
        self.version = version
        self.name = name
        self.isPrerelease = isPrerelease
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.notes = notes
        self.assets = assets
    }

    /// 给用户点的链接：优先 `.dmg`（人工安装用），没有就退回 release 页面。
    ///
    /// **刻意不退回 `.zip`**：zip 是给自动更新器吃的，用户双击解压出来的 `.app`
    /// 会落在「下载」目录，从那里运行会触发 App Translocation（随机只读路径），
    /// 后台组件装不上——这正是发布手册里反复警告的那个坑。
    /// 退回 release 页面更安全：页面上有安装说明、校验和和全部附件。
    public var downloadURL: URL? {
        if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }), dmg.downloadURL != nil {
            return dmg.downloadURL
        }
        return pageURL
    }

    /// 界面上一行能放下的版本说明：`FunFan 1.0.0-alpha.7`。
    public var displayName: String {
        version.description
    }
}

/// GitHub 发布列表（`GET /repos/{owner}/{repo}/releases`）的解析。
///
/// 刻意**不用 Codable**：一个条目里某个字段类型不对（GitHub 偶尔会这么干，
/// 或者中间层塞了别的东西），Codable 会让整次解码失败——用户看到「检查更新失败」，
/// 而实际上只是列表里有一条坏数据。这里逐条抽取，坏的跳过，好的照用。
public enum ReleaseFeed {

    public static func decode(_ data: Data) throws -> [ReleaseInfo] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UpdateFailure.malformed("发布列表不是合法 JSON")
        }

        guard let entries = object as? [[String: Any]] else {
            throw UpdateFailure.malformed("发布列表不是数组")
        }

        return entries.compactMap(parse(_:))
    }

    private static func parse(_ entry: [String: Any]) -> ReleaseInfo? {
        guard let tag = entry["tag_name"] as? String,
              let version = SemanticVersion(parsing: tag) else {
            return nil
        }

        // 草稿绝对不能推给用户：它只是 maintainer 还没发的东西。
        // 匿名接口本来就不返回草稿，但带着 token 或用镜像时会，所以这里再挡一次。
        if entry["draft"] as? Bool == true { return nil }

        let declaredPrerelease = entry["prerelease"] as? Bool ?? false
        let assets = (entry["assets"] as? [[String: Any]] ?? []).compactMap { raw -> ReleaseAsset? in
            guard let name = raw["name"] as? String else { return nil }
            return ReleaseAsset(
                name: name,
                downloadURL: (raw["browser_download_url"] as? String).flatMap(URL.init(string:))
            )
        }

        return ReleaseInfo(
            tag: tag,
            version: version,
            name: entry["name"] as? String,
            // tag 带 `-alpha` 其实就是预发布，即使 flag 忘了勾也不能当成正式版推给
            // 正式版用户。
            isPrerelease: declaredPrerelease || version.isPrerelease,
            publishedAt: (entry["published_at"] as? String).flatMap(parseDate(_:)),
            pageURL: (entry["html_url"] as? String).flatMap(URL.init(string:)),
            notes: entry["body"] as? String ?? "",
            assets: assets
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
