import Foundation

/// Declared Maven dependencies only. Never resolves artifacts or executes a build.
final class AIJavaDependencies: NSObject, XMLParserDelegate {
    private var path: [String] = [], values: [String:String] = [:], text = ""
    private var dependencies: [String] = []
    static func maven(_ source: String) -> [String] {
        guard source.utf8.count <= 262144, !source.uppercased().contains("<!DOCTYPE"), !source.uppercased().contains("<!ENTITY") else { return [] }
        let delegate = AIJavaDependencies(), parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { return [] }; return delegate.dependencies
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        path.append(name); text = ""
        if name == "dependency" { values = [:] }
        if path.count > 100 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 4096 { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if path.count > 1, path[path.count-2] == "dependency", ["groupId", "artifactId", "version", "scope"].contains(name) { values[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "dependency", let group = values["groupId"], let artifact = values["artifactId"] {
            let managed = path.contains("dependencyManagement") ? " managed" : ""
            dependencies.append(group + ":" + artifact + ":" + (values["version"] ?? "inherited/unresolved") + " scope=" + (values["scope"] ?? "compile") + managed)
            if dependencies.count >= 300 { parser.abortParsing() }
        }
        if !path.isEmpty { path.removeLast() }; text = ""
    }
}
