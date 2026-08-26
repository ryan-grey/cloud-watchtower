import Foundation

/// Tiny read-only XML tree. CloudWatch and STS speak the AWS Query protocol and answer in
/// XML; Budgets and Cost Explorer speak JSON. This covers the XML half.
final class XMLNode {
    let name: String
    var text: String = ""
    private(set) var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String) { self.name = name }

    fileprivate func add(_ child: XMLNode) {
        child.parent = self
        children.append(child)
    }

    /// All direct children with the given name.
    subscript(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// First direct child with the given name.
    func first(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    /// Depth-first search for the first descendant with the given name.
    func find(_ name: String) -> XMLNode? {
        if self.name == name { return self }
        for child in children {
            if let hit = child.find(name) { return hit }
        }
        return nil
    }

    /// Depth-first search for all descendants with the given name.
    func findAll(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        if self.name == name { out.append(self) }
        for child in children { out.append(contentsOf: child.findAll(name)) }
        return out
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var doubleValue: Double? { Double(trimmed) }

    static func parse(_ data: Data) -> XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = XMLNode(name: name)
            stack.last?.add(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
