import Foundation

enum FileType: String {
    case script
    case binary
}

struct Classification {
    let type: FileType
    let lang: String
}

enum Classifier {
    static func classify(_ path: String) -> Classification {
        let fm = FileManager.default

        // Resolve symlinks for content inspection
        let resolved: String
        if let attrs = try? fm.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? path
            if target.hasPrefix("/") {
                resolved = target
            } else {
                resolved = (path as NSString).deletingLastPathComponent + "/" + target
            }
        } else {
            resolved = path
        }

        // Try Mach-O detection on resolved path
        if let lang = MachO.detectLanguage(at: resolved) {
            return Classification(type: .binary, lang: lang)
        }

        // Check first bytes for Mach-O magic (might fail to parse but still be binary)
        if let data = fm.contents(atPath: resolved)?.prefix(4), data.count == 4 {
            let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            if magic == 0xFEEDFACF || magic == 0xCFFAEDFE ||
               magic == 0xCAFEBABE || magic == 0xBEBAFECA {
                return Classification(type: .binary, lang: "")
            }
        }

        // Script: parse shebang
        if let data = fm.contents(atPath: resolved),
           let head = String(data: data.prefix(256), encoding: .utf8) {
            let firstLine = head.components(separatedBy: .newlines).first ?? ""
            let lang = detectScriptLang(firstLine)
            return Classification(type: .script, lang: lang)
        }

        // Fallback: unreadable (setuid, etc.)
        return Classification(type: .binary, lang: "")
    }

    private static func detectScriptLang(_ shebang: String) -> String {
        if shebang.contains("python") { return "python" }
        if shebang.contains("bash") { return "bash" }
        if shebang.contains("zsh") { return "zsh" }
        if shebang.contains("ruby") { return "ruby" }
        if shebang.contains("node") { return "node" }
        if shebang.contains("perl") { return "perl" }
        if shebang.contains("/sh") || shebang.contains("env sh") { return "shell" }
        return ""
    }
}
