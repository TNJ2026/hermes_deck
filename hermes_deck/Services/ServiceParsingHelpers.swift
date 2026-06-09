import Foundation

extension String {
    var sessionTextValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "—" ? nil : value
    }

    var pluginTextValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var pluginFirstParagraph: String? {
        components(separatedBy: "\n\n").first?.pluginTextValue
    }

    var pluginCleanedYAMLValue: String {
        var value = trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}
