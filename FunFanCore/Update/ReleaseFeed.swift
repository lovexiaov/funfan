import Foundation

/// 一条 GitHub Release 里我们真正会用到的字段。
public struct ReleaseInfo: Equatable {
    public let tag: String
    public let version: SemanticVersion
    public let name: String?
    public let isPrerelease: Bool
    public let publishedAt: Date?
    /// 发布页地址。两个数据源都提供，永远可用。
    public let pageURL: URL?
    /// `.dmg` 直链。**只有 REST 接口给得了**——Atom 订阅不带附件地址，
    /// 备用源下为 nil，界面退回发布页（见 `targetURL`）。
    public let downloadURL: URL?
    /// 发布说明（Atom 源已从 HTML 去掉标签）。
    public let notes: String

    public init(
        tag: String,
        version: SemanticVersion,
        name: String?,
        isPrerelease: Bool,
        publishedAt: Date?,
        pageURL: URL?,
        downloadURL: URL? = nil,
        notes: String
    ) {
        self.tag = tag
        self.version = version
        self.name = name
        self.isPrerelease = isPrerelease
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.notes = notes
    }

    /// 给用户点的链接：有 `.dmg` 直链就用它，否则退回发布页。
    ///
    /// **刻意不用 `.zip`**：那是给自动更新器吃的，用户双击解压出的 `.app` 会落在
    /// 「下载」目录，从那里运行会触发 App Translocation（随机只读路径），
    /// 后台组件装不上——发布手册里反复警告的坑。发布页有说明、校验和与全部附件。
    public var targetURL: URL? {
        downloadURL ?? pageURL
    }

    /// 界面上一行能放下的版本说明：`1.0.0-alpha.7`。
    public var displayName: String {
        version.description
    }
}

/// 发布数据的解析。两个数据源各一份，产出一致的 `[ReleaseInfo]`。
///
/// **为什么是两个源**（2026-11-11 实测）：
/// - REST `api.github.com/.../releases`：字段最全（能拿到 dmg 直链、草稿标记），
///   但未认证时**按 IP** 限 60 次/小时。共享出口（CGNAT / 公司网关 / 代理）
///   的用户会在完全正常的使用下被告知「限流了」——这正是用户报的问题。
/// - Atom `github.com/.../releases.atom`：网页端点，没有这个配额，但拿不到附件地址，
///   而且 `github.com` 在部分网络里比 `api.github.com` 更难连通。
///
/// 所以：REST 为主，**额度耗尽或连不上**时才换 Atom（见 `UpdateChecker.check`）。
/// 反过来「只用 Atom」会把「限流」换成「连不上」，不是改进。
public enum ReleaseFeed {

    /// 按内容自动识别格式（`<` 开头当 Atom，其余当 JSON）。给探针的 `--feed` 用。
    public static func decode(_ data: Data) throws -> [ReleaseInfo] {
        let head = data.prefix(64).drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        return head.first == UInt8(ascii: "<") ? try decodeAtom(data) : try decodeJSON(data)
    }

    // MARK: - Atom（备用源）

    public static func decodeAtom(_ data: Data) throws -> [ReleaseInfo] {
        let delegate = AtomReleaseParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // 不处理命名空间：Atom 用默认命名空间，元素名就是 `entry` / `title`。
        // 一旦按命名空间解析，名字会变成 `{http://www.w3.org/2005/Atom}entry`。
        parser.shouldProcessNamespaces = false

        guard parser.parse(), delegate.sawFeed else {
            throw UpdateFailure.malformed("发布订阅不是合法的 Atom（XML 解析失败）")
        }
        return delegate.entries.compactMap(atomInfo(_:))
    }

    private static func atomInfo(_ entry: AtomReleaseParser.Entry) -> ReleaseInfo? {
        guard let tag = atomTag(fromLink: entry.link, id: entry.id),
              let version = SemanticVersion(parsing: tag) else {
            return nil
        }

        return ReleaseInfo(
            tag: tag,
            version: version,
            name: entry.title.isEmpty ? nil : entry.title,
            // Atom 没有 prerelease 字段，只能看版本号自己带不带预发布后缀。
            // 不能改成「标题里有没有 alpha」——标题是人手写的，格式随时变。
            isPrerelease: version.isPrerelease,
            publishedAt: parseDate(entry.updated) ?? parseDate(entry.published),
            pageURL: URL(string: entry.link),
            downloadURL: nil,
            notes: plainText(fromHTML: entry.content)
        )
    }

    /// 从条目里取出 tag。
    ///
    /// 优先用 `<link href>`：真实 feed 里 alpha.8 的 `<title>` 是「FunFan 1.0.0-alpha.8」，
    /// alpha.7 的却是「v1.0.0-alpha.7」——标题格式不可靠，链接才是天然的 tag 载体。
    /// `<link>` 缺失时退回 `<id>` 的末段（`tag:github.com,2008:Repository/<id>/<tag>`）。
    private static func atomTag(fromLink link: String, id: String) -> String? {
        if let range = link.range(of: "/releases/tag/") {
            let raw = String(link[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let decoded = raw.removingPercentEncoding ?? raw
            if !decoded.isEmpty { return decoded }
        }
        if let range = id.range(of: "Repository/") {
            let rest = id[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let raw = String(rest[rest.index(after: slash)...])
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    // MARK: - REST（主源）

    /// 刻意**不用 Codable**：一个条目里某个字段类型不对（GitHub 偶尔会这么干，
    /// 或者中间层塞了别的东西），Codable 会让整次解码失败——用户看到「检查更新失败」，
    /// 而实际上只是列表里有一条坏数据。这里逐条抽取，坏的跳过，好的照用。
    public static func decodeJSON(_ data: Data) throws -> [ReleaseInfo] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UpdateFailure.malformed("发布列表不是合法 JSON")
        }

        guard let entries = object as? [[String: Any]] else {
            throw UpdateFailure.malformed("发布列表不是数组")
        }
        return entries.compactMap(jsonInfo(_:))
    }

    private static func jsonInfo(_ entry: [String: Any]) -> ReleaseInfo? {
        guard let tag = entry["tag_name"] as? String,
              let version = SemanticVersion(parsing: tag) else {
            return nil
        }

        // 草稿绝对不能推给用户：它只是 maintainer 还没发的东西。
        // 匿名接口本来就不返回草稿，但带着 token 或用镜像时会，所以这里再挡一次。
        if entry["draft"] as? Bool == true { return nil }

        let dmg = (entry["assets"] as? [[String: Any]] ?? []).first { raw in
            (raw["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }

        return ReleaseInfo(
            tag: tag,
            version: version,
            name: entry["name"] as? String,
            // tag 带 `-alpha` 其实就是预发布，即使 flag 忘了勾也不能当成正式版推给
            // 正式版用户。
            isPrerelease: (entry["prerelease"] as? Bool ?? false) || version.isPrerelease,
            publishedAt: (entry["published_at"] as? String).flatMap(parseDate(_:)),
            pageURL: (entry["html_url"] as? String).flatMap(URL.init(string:)),
            downloadURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            notes: entry["body"] as? String ?? ""
        )
    }

    // MARK: - 共用

    /// 发布说明在 Atom 里是 HTML。界面只放得下一两行，留着标签会直接看见 `<h3>`。
    static func plainText(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }

        var text = ""
        var tagBuffer = ""
        var insideTag = false

        for character in html {
            switch character {
            case "<":
                insideTag = true
                tagBuffer.removeAll(keepingCapacity: true)
            case ">":
                insideTag = false
                if breaksLine(tagBuffer) { text.append("\n") }
            default:
                if insideTag { tagBuffer.append(character) } else { text.append(character) }
            }
        }

        return tidy(decodeEntities(text))
    }

    /// 块级标签换成换行，其余（`<strong>`、`<code>`）直接丢掉——它们的文字会自然保留。
    private static func breaksLine(_ rawTag: String) -> Bool {
        let trimmed = rawTag.trimmingCharacters(in: .whitespaces)
        let withoutSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let name = withoutSlash.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        switch name {
        case "br", "p", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
             "blockquote", "tr", "td", "th", "pre", "details", "summary", "table":
            return true
        default:
            return false
        }
    }

    private static func decodeEntities(_ raw: String) -> String {
        var text = raw
        // `&amp;` 必须最后解：先解它会把 `&amp;lt;` 变成 `<`，多解一层。
        let pairs = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (entity, replacement) in pairs {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 去掉标签后留下的空行与行首缩进。
    private static func tidy(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// 只做一件事：把 Atom 里的 `<entry>` 逐个抽成字段。
///
/// 不引第三方 XML 库，也刻意不做完整的 Atom 模型——我们只要几个字段，
/// 多建模一分就多一处会随格式变化而崩的地方。
private final class AtomReleaseParser: NSObject, XMLParserDelegate {

    struct Entry {
        var id = ""
        var title = ""
        var updated = ""
        var published = ""
        var link = ""
        var content = ""
    }

    private(set) var entries: [Entry] = []
    /// 根节点是不是 `<feed>`。用于区分「空订阅（仓库还没发版）」和
    /// 「返回的根本不是订阅（代理返回的登录页 / 错误 JSON）」——后者必须报错，
    /// 否则会被当成「已是最新」，用户永远收不到更新且毫无提示。
    private(set) var sawFeed = false

    private var current: Entry?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "feed":
            sawFeed = true
        case "entry":
            current = Entry()
        case "link":
            // feed 级别也有一个 link（指向 releases 页面），只在 entry 内取值。
            guard current != nil else { return }
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate", let href = attributeDict["href"] {
                current?.link = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { text = "" }
        guard current != nil else { return }

        switch elementName {
        case "id": current?.id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "title": current?.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "updated": current?.updated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "published": current?.published = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "content": current?.content = text
        case "entry":
            if let entry = current { entries.append(entry) }
            current = nil
        default:
            break
        }
    }
}
