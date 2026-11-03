import Foundation

struct Field: Identifiable, Hashable {
    let key: String
    var value: String
    var id: String { key }
}

/// Minimaler XML-Baum für die Router-Antworten.
final class XMLNode: @unchecked Sendable {
    let name: String
    fileprivate(set) var text: String = ""
    fileprivate(set) var children: [XMLNode] = []

    init(name: String) {
        self.name = name
    }

    var value: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    subscript(key: String) -> String? {
        children.first { $0.name == key }?.value
    }

    /// Direkte Kindelemente als Schlüssel/Wert-Liste (in Original-Reihenfolge).
    var fields: [Field] {
        children.map { Field(key: $0.name, value: $0.value) }
    }

    static func parse(_ data: Data) -> XMLNode? {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

extension String {
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
