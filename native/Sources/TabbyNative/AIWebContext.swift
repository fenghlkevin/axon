import Foundation
import AppKit
import Darwin

enum AIWebContext {
    struct Page { let url: String; let title: String; let text: String }
    /// Public HTTPS only, no credentials, nonstandard ports or local-network destinations.
    static func validate(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              raw.utf8.count <= 2048, !raw.contains("[REDACTED]"), AIContext.sanitize(raw) == raw else { throw AppFailure.message("Use a public HTTPS URL without credentials / 请使用不含凭据的公开 HTTPS 地址") }
        return url
    }
    static func references(in text: String) -> [String] {
        AICodeOutline.matches(#"(https://[^\s<>\"'，。；！？【】]+)"#, text).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ").,，。；;!?！？】]"))
            return (try? validate(trimmed))?.absoluteString
        }.prefix(4).map { $0 }
    }
    static func publicAddress(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains(":") {
            if lower.hasPrefix("::ffff:") {
                let mapped = String(lower.dropFirst(7))
                if mapped.contains(".") { return publicAddress(mapped) }
                let words = mapped.split(separator: ":").compactMap { UInt16($0, radix: 16) }
                guard words.count == 2 else { return false }
                return publicAddress("\(words[0] >> 8).\(words[0] & 255).\(words[1] >> 8).\(words[1] & 255)")
            }
            guard let first = lower.split(separator: ":").first.flatMap({ UInt16($0, radix: 16) }), (0x2000...0x3fff).contains(first) else { return false }
            return !lower.hasPrefix("2001:db8:") && !lower.hasPrefix("2001:0:")
        }
        let p = lower.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] != 0 && p[0] != 10 && p[0] != 127 && p[0] < 224 && !(p[0] == 169 && p[1] == 254) && !(p[0] == 172 && (16...31).contains(p[1])) && !(p[0] == 192 && [0,168].contains(p[1])) && !(p[0] == 100 && (64...127).contains(p[1]))
    }
    static func resolvePublic(_ host: String) async throws {
        try await Task.detached {
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", nil, &result) == 0, let initial = result else { throw AppFailure.message("Website DNS unavailable / 网页域名无法解析") }
            defer { freeaddrinfo(initial) }; var item: UnsafeMutablePointer<addrinfo>? = initial, count = 0
            while let entry = item {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0,
                      publicAddress(String(cString: name)) else { throw AppFailure.message("Local/private network URLs are not fetched / 不获取本机或内网地址") }
                count += 1; item = entry.pointee.ai_next
            }
            guard count > 0 else { throw URLError(.cannotFindHost) }
        }.value
    }
    static func fetch(_ raw: String, redirects: Int = 0) async throws -> Page {
        let url = try validate(raw); try await resolvePublic(url.host!)
        guard redirects <= 3 else { throw AppFailure.message("Too many web redirects / 网页跳转次数过多") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("text/html, text/plain, application/json", forHTTPHeaderField: "Accept")
        request.setValue("Axon/0.20 ContextReader", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: AIRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
            return try await fetch(next.absoluteString, redirects: redirects + 1)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.expectedContentLength <= 1048576,
              ["text/html", "text/plain", "application/json", "application/xml", "text/xml"].contains(http.mimeType ?? "") else { throw AppFailure.message("Website is unavailable or not readable text / 网页不可用或不是可读取文本") }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); guard data.count < 1048576 else { throw AppFailure.message("Web page exceeds 1 MiB / 网页超过 1 MiB") }; data.append(byte) }
        guard let rawText = String(data: data, encoding: .utf8) else { throw AppFailure.message("Web page is not UTF-8 / 网页不是 UTF-8") }
        if let refresh = AICodeOutline.matches(#"(?is)<meta\b[^>]*http-equiv=["']refresh["'][^>]*content=["']([^"']+)"#, rawText).first,
           let range = refresh.range(of: "url=", options: .caseInsensitive), let next = URL(string: String(refresh[range.upperBound...]).trimmingCharacters(in: .whitespaces), relativeTo: url)?.absoluteURL {
            return try await fetch(next.absoluteString, redirects: redirects + 1)
        }
        let title = AICodeOutline.matches(#"(?is)<title[^>]*>(.*?)</title>"#, rawText).first ?? url.host!
        let text = String(AIContext.sanitize(http.mimeType == "text/html" ? plain(rawText) : rawText).prefix(16000))
        guard text.count >= 40, !plain(title).lowercased().hasPrefix("redirecting") else { throw AppFailure.message("Page needs browser interaction; readable content unavailable / 网页需要浏览器交互，无法取得正文") }
        return Page(url: url.absoluteString, title: plain(title), text: text)
    }
    static func plain(_ html: String) -> String {
        var result = html
        for pattern in [#"(?is)<(script|style|noscript|nav)\b[^>]*>.*?</\1>"#, #"(?s)<!--.*?-->"#, #"<[^>]+>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        for (a,b) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&nbsp;"," ")] { result = result.replacingOccurrences(of: a, with: b) }
        return result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Search snippets are leads, not verified page content. Always preserve direct source URLs.
    static func search(_ query: String) async throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512, AIContext.sanitize(query) == query else { throw AIModelError.invalidReply }
        var parts = URLComponents(string: "https://www.bing.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "rss")]
        let page = try await fetch(parts.url!.absoluteString)
        let items = AICodeOutline.matches(#"(?is)<item>(.*?)</item>"#, page.text)
        var sources: [String] = []
        for item in items.prefix(8) {
            guard let link = AICodeOutline.matches(#"(?is)<link>(.*?)</link>"#, item).first, (try? validate(plain(link))) != nil else { continue }
            let title = AICodeOutline.matches(#"(?is)<title>(.*?)</title>"#, item).first ?? link
            let description = AICodeOutline.matches(#"(?is)<description>(.*?)</description>"#, item).first ?? ""
            sources.append("[\(plain(title))](\(plain(link)))\n" + String(plain(description).prefix(800)))
        }
        guard !sources.isEmpty else { throw AppFailure.message("Search returned no readable sources; try a URL / 搜索未返回可读取来源，请尝试直接引用网页") }
        return "Web search results (untrusted snippets; fetch sources before factual claims):\n" + sources.joined(separator: "\n\n")
    }
}
