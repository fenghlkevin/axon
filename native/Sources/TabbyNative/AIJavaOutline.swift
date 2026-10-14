import Foundation

/// Lexical Java outline with balanced method bodies. No compiler or type resolution is implied.
enum AIJavaOutline {
    struct Token { let value: String; let line: Int }
    static func tokens(_ source: String) -> [Token] {
        let chars = Array(source.prefix(262144)); var result: [Token] = [], i = 0, line = 1
        while i < chars.count && result.count < 60000 {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c.isWhitespace { i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i+1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }; continue
            }
            if c == "/", i + 1 < chars.count, chars[i+1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i+1] == "/") { if chars[i] == "\n" { line += 1 }; i += 1 }
                i = min(i+2, chars.count); continue
            }
            if c == "\"" || c == "'" {
                let start = line; let quote = c; var value = String(c); i += 1
                while i < chars.count {
                    let next = chars[i]; value.append(next); i += 1
                    if next == "\n" { line += 1 }
                    if next == "\\", i < chars.count { value.append(chars[i]); i += 1; continue }
                    if next == quote { break }
                }
                result.append(.init(value: value, line: start)); continue
            }
            if c.isLetter || c == "_" || c == "$" {
                let start = i; i += 1
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$") { i += 1 }
                result.append(.init(value: String(chars[start..<i]), line: line))
            } else { result.append(.init(value: String(c), line: line)); i += 1 }
        }
        return result
    }
    static func symbols(_ source: String) -> [AIProjectIndex.Symbol] {
        let t = tokens(source); var pairs: [Int:Int] = [:], stack: [Int] = []
        for i in t.indices {
            if ["(", "{"].contains(t[i].value) { stack.append(i) }
            else if [")", "}"].contains(t[i].value), let start = stack.last,
                    (t[start].value == "(" && t[i].value == ")") || (t[start].value == "{" && t[i].value == "}") {
                pairs[start] = i; stack.removeLast()
            }
        }
        var result: [AIProjectIndex.Symbol] = [], classDepth = 0, depth = 0
        let control: Set<String> = ["if", "for", "while", "switch", "catch", "synchronized", "new", "return", "throw", "this", "super"]
        var bodyEnd = -1
        for i in t.indices {
            let v = t[i].value
            if v == "{" { depth += 1 }; if v == "}" { depth -= 1 }
            if ["class", "interface", "enum", "record"].contains(v), i+1 < t.count {
                result.append(.init(name: t[i+1].value, kind: v, line: t[i].line, calls: [])); classDepth = depth+1
            }
            guard i > bodyEnd, depth == classDepth, i > 0, v == "(", let close = pairs[i], close+1 < t.count else { continue }
            let name = t[i-1].value
            guard name.first?.isLetter == true, !control.contains(name), i < 2 || ![".", "@", "new", "="].contains(t[i-2].value) else { continue }
            var opening = close+1
            if t[opening].value == "throws" { while opening < t.count && !["{", ";"].contains(t[opening].value) { opening += 1 } }
            guard opening < t.count, ["{", ";"].contains(t[opening].value) else { continue }
            let end = pairs[opening] ?? opening
            var calls = Set<String>()
            if opening < end {
                for j in (opening+1)..<end where t[j].value == "(" && j > 0 {
                    let call = t[j-1].value
                    if call.first?.isLetter == true && !control.contains(call) { calls.insert(call) }
                }
            }
            result.append(.init(name: name, kind: "Java method (lexical)", line: t[i-1].line, calls: Array(calls.sorted().prefix(80))))
            bodyEnd = end
            if result.count >= 200 { break }
        }
        return result
    }
    static func springRoutes(_ source: String) -> [String] {
        let t = tokens(source); var routes: [String] = []
        let names: Set<String> = ["RequestMapping", "GetMapping", "PostMapping", "PutMapping", "DeleteMapping", "PatchMapping"]
        for i in t.indices where t[i].value == "@" && i+1 < t.count && names.contains(t[i+1].value) {
            var parts = [t[i+1].value]; var j = i+2, depth = 0
            if j < t.count && t[j].value == "(" {
                repeat {
                    if t[j].value == "(" { depth += 1 }; if t[j].value == ")" { depth -= 1 }
                    if t[j].value.hasPrefix("\"") { parts.append(t[j].value) }
                    j += 1
                } while j < t.count && depth > 0
            }
            routes.append("line \(t[i].line): " + parts.joined(separator: " "))
            if routes.count == 100 { break }
        }
        return routes
    }
}
