import ArgumentParser
import CLICore
import Foundation

@main
struct PathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Display PATH entries with sources and analysis.",
        discussion: """
        Shows each directory in your PATH with bin counts, ownership, \
        and where it was configured.

        Examples:
          path                    Show PATH summary table
          path --list             List all executables in each directory
          path --list --top 10    Show first 10 executables per directory
          path --dir /usr/local/bin  List executables in a specific directory
          path --shadows          Find shadowed executables across PATH
          path --dupes            Show duplicate PATH entries
        """,
        version: "2.0.0"
    )

    @Flag(name: [.customShort("d"), .long], help: "Show only duplicate entries")
    var dupes = false

    @Flag(name: [.customShort("l"), .long], help: "List executables in each directory")
    var list = false

    @Flag(name: [.customShort("s"), .long], help: "Show only shadowed executables (implies --list)")
    var shadows = false

    @Option(name: [.long], help: "Filter to a specific directory")
    var dir: String?

    @Option(name: [.long], help: "Show only the first N executables per directory")
    var top: Int?

    mutating func run() async {
        if shadows { list = true }
        if dir != nil { list = true }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Collect known sources: path -> source file
        var sources: [(path: String, source: String)] = []

        // /etc/paths
        if let contents = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { sources.append((p, "/etc/paths")) }
            }
        }

        // /etc/paths.d/*
        let fm = FileManager.default
        if let pathsD = try? fm.contentsOfDirectory(atPath: "/etc/paths.d") {
            for file in pathsD.sorted() {
                let filePath = "/etc/paths.d/\(file)"
                if let contents = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    for line in contents.split(separator: "\n") {
                        let p = line.trimmingCharacters(in: .whitespaces)
                        if !p.isEmpty { sources.append((p, filePath)) }
                    }
                }
            }
        }

        // Shell RC files
        let rcFiles = [
            "\(home)/.zshenv", "\(home)/.zshrc", "\(home)/.zprofile",
            "\(home)/.bashrc", "\(home)/.bash_profile", "\(home)/.profile",
            "\(home)/.config/zsh/.zshenv", "\(home)/.config/zsh/.zshrc",
            "\(home)/.config/zsh/.zprofile",
            "/etc/zshenv", "/etc/zshrc", "/etc/zprofile", "/etc/profile",
        ]

        // Known eval tools and their typical PATH prefixes
        let evalTools: [(pattern: String, paths: [String])] = [
            ("brew shellenv", ["/opt/homebrew/bin", "/opt/homebrew/sbin"]),
            ("rbenv init", ["\(home)/.rbenv/shims", "\(home)/.rbenv/bin"]),
            ("pyenv init", ["\(home)/.pyenv/shims", "\(home)/.pyenv/bin"]),
            ("nodenv init", ["\(home)/.nodenv/shims", "\(home)/.nodenv/bin"]),
            ("swiftenv init", ["\(home)/.swiftenv/shims", "\(home)/.swiftenv/bin"]),
        ]

        for rc in rcFiles {
            guard let contents = try? String(contentsOfFile: rc, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Detect eval patterns (e.g. eval "$(/opt/homebrew/bin/brew shellenv)")
                if trimmed.hasPrefix("eval ") || trimmed.hasPrefix("eval\t") {
                    for tool in evalTools {
                        if trimmed.contains(tool.pattern) {
                            let sourceLabel = "\(rc) (via \(tool.pattern.split(separator: " ").first ?? "eval"))"
                            for p in tool.paths {
                                sources.append((p, sourceLabel))
                            }
                        }
                    }
                    continue
                }

                guard trimmed.contains("PATH=") else { continue }
                // Extract the value after PATH=
                guard let eqRange = trimmed.range(of: "PATH=") else { continue }
                var value = String(trimmed[eqRange.upperBound...])
                value = value.replacingOccurrences(of: "\"", with: "")
                value = value.replacingOccurrences(of: "'", with: "")

                for part in value.split(separator: ":").map(String.init) {
                    if part == "$PATH" || part == "${PATH}" || part.isEmpty { continue }
                    let expanded = expandVars(part, home: home)
                    sources.append((expanded, rc))
                }
            }
        }

        // Process actual PATH
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []

        struct Entry {
            let index: Int
            let path: String
            let binCount: Int
            let exists: Bool
            let isDuplicate: Bool
            let owner: String
            let writable: Bool
            let source: String
        }

        var seen = Set<String>()
        var entries: [Entry] = []

        for (i, p) in pathEntries.enumerated() {
            let isDup = seen.contains(p)
            seen.insert(p)

            var exists = false
            var binCount = 0
            var owner = ""
            var writable = false

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                exists = true
                writable = fm.isWritableFile(atPath: p)
                // Count executables
                if let items = try? fm.contentsOfDirectory(atPath: p) {
                    for item in items {
                        let fullPath = "\(p)/\(item)"
                        if fm.isExecutableFile(atPath: fullPath) {
                            binCount += 1
                        }
                    }
                }
                // Check ownership
                if let attrs = try? fm.attributesOfItem(atPath: p) {
                    owner = (attrs[.ownerAccountName] as? String) ?? ""
                }
            }

            // Find source
            let source = sources.first(where: { $0.path == p })?.source ?? "unknown"
            let sourceDisplay = source.replacingOccurrences(of: home, with: "~")

            entries.append(Entry(
                index: i + 1,
                path: p,
                binCount: binCount,
                exists: exists,
                isDuplicate: isDup,
                owner: owner,
                writable: writable,
                source: sourceDisplay
            ))
        }

        // Filter if --dupes
        var displayEntries = dupes ? entries.filter(\.isDuplicate) : entries

        // Filter if --dir
        if let dirFilter = dir {
            displayEntries = displayEntries.filter { $0.path.hasSuffix(dirFilter) || $0.path == dirFilter }
        }

        // Track shadowed names across all directories
        var seenNames: [String: String] = [:]

        if list {
            // --list mode: show executables per directory
            print()
            print("\(styled("PATH", .bold, .cyan)) \(styled("\(pathEntries.count) entries", .dim))")

            var totalExecs = 0
            var scriptCount = 0
            var binaryCount = 0
            var containerCount = 0
            var shadowedCount = 0

            for entry in displayEntries {
                guard entry.exists else {
                    print()
                    print("\(styled(shortPath(entry.path, home: home), .bold, .red))  \(styled("missing", .red))  \(styled("(\(entry.source))", .gray))")
                    continue
                }

                guard let items = try? fm.contentsOfDirectory(atPath: entry.path) else { continue }

                let executables = items.filter { name in
                    guard !name.hasPrefix(".") else { return false }
                    let fullPath = "\(entry.path)/\(name)"
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                        if isDir.boolValue { return false }
                    }
                    return fm.isExecutableFile(atPath: fullPath)
                }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

                guard !executables.isEmpty else { continue }

                let results: [(String, Classification, String)] = await withTaskGroup(
                    of: (String, Classification, String).self
                ) { group in
                    for name in executables {
                        group.addTask {
                            let taskFM = FileManager.default
                            let fullPath = "\(entry.path)/\(name)"
                            let classification = Classifier.classify(fullPath)
                            var detail = ""

                            if let attrs = try? taskFM.attributesOfItem(atPath: fullPath),
                               attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                               let target = try? taskFM.destinationOfSymbolicLink(atPath: fullPath) {
                                let display: String
                                if target.hasPrefix("/") {
                                    display = target
                                } else {
                                    display = (fullPath as NSString).deletingLastPathComponent + "/" + target
                                }
                                let shortened = display.hasPrefix(home)
                                    ? "~" + display.dropFirst(home.count)
                                    : display
                                detail = "\u{2192} \(shortened)"
                            }

                            return (name, classification, detail)
                        }
                    }

                    var collected: [(String, Classification, String)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
                }

                var rows: [(name: String, type: FileType, lang: String, detail: String)] = []
                for (name, classification, symlinkDetail) in results {
                    var detail = symlinkDetail
                    if let firstDir = seenNames[name] {
                        let shortened = shortPath(firstDir, home: home)
                        detail = "shadowed by \(shortened)"
                    } else {
                        seenNames[name] = entry.path
                    }
                    rows.append((name, classification.type, classification.lang, detail))
                }

                // Track stats
                totalExecs += rows.count
                for row in rows {
                    switch row.type {
                    case .script: scriptCount += 1
                    case .binary: binaryCount += 1
                    case .container: containerCount += 1
                    }
                    if row.detail.hasPrefix("shadowed by") {
                        shadowedCount += 1
                    }
                }

                if shadows {
                    let shadowed = rows.filter { $0.detail.hasPrefix("shadowed by") }
                    if !shadowed.isEmpty {
                        printBinsTable(dir: entry.path, rows: shadowed, home: home, top: top)
                    }
                } else {
                    printBinsTable(dir: entry.path, rows: rows, home: home, top: top)
                }
            }

            if shadows && seenNames.isEmpty {
                print("\nNo shadowed executables found.")
            }

            // Summary footer
            print()
            var parts: [String] = []
            parts.append("\(styled("\(totalExecs)", .yellow)) \(styled("executables", .dim))")
            parts.append("\(styled("\(scriptCount)", .cyan)) \(styled("scripts", .dim))")
            parts.append("\(styled("\(binaryCount)", .red)) \(styled("binaries", .dim))")
            if containerCount > 0 {
                parts.append("\(styled("\(containerCount)", .yellow)) \(styled("containers", .dim))")
            }
            if shadowedCount > 0 {
                parts.append("\(styled("\(shadowedCount)", .orange)) \(styled("shadowed", .dim))")
            }
            print(parts.joined(separator: styled("  \u{00B7}  ", .dim)))
        } else {
            // Default mode: directory summary table

            // Header
            print()
            print("\(styled("PATH", .bold, .cyan)) \(styled("\(pathEntries.count) entries", .dim))")
            print()

            // Dynamic column widths
            let pathW = max("Directory".count, displayEntries.map(\.path.count).max() ?? 0)
            let binsW = max("Bins".count, displayEntries.map { String($0.binCount).count }.max() ?? 0)
            let ownerW = max("Owner".count, displayEntries.map(\.owner.count).max() ?? 0)
            let writableW = "Writable".count

            // Table header
            let hPath = "Directory".padding(toLength: pathW, withPad: " ", startingAt: 0)
            let hBins = "Bins".padding(toLength: binsW, withPad: " ", startingAt: 0)
            let hOwner = "Owner".padding(toLength: ownerW, withPad: " ", startingAt: 0)
            let hWritable = "Writable"
            print(styled("  #  \(hPath)  \(hBins)  \(hOwner)  \(hWritable)  Source", .lightGray))

            // Entries
            for entry in displayEntries {
                let pathColor: Color
                if !entry.exists {
                    pathColor = .red
                } else if entry.path.contains("/homebrew/") || entry.path.contains("/Homebrew/") {
                    pathColor = .cyan
                } else if entry.owner != "root" {
                    pathColor = .magenta
                } else {
                    pathColor = .green
                }

                let idxColor: Color = entry.isDuplicate ? .orange : .gray
                let ownerColor: Color = entry.owner == "root" ? .green : .magenta
                let writableStr = entry.writable ? "yes" : "-"
                let writableColor: Color = entry.writable ? .yellow : .dim

                let paddedPath = entry.path.padding(toLength: pathW, withPad: " ", startingAt: 0)
                let binStr = String(entry.binCount).padding(toLength: binsW, withPad: " ", startingAt: 0)
                let ownerStr = entry.owner.padding(toLength: ownerW, withPad: " ", startingAt: 0)
                let wStr = writableStr.padding(toLength: writableW, withPad: " ", startingAt: 0)

                print(" \(styled(String(format: "%2d", entry.index), idxColor))  \(styled(paddedPath, pathColor))  \(styled(binStr, .yellow))  \(styled(ownerStr, ownerColor))  \(styled(wStr, writableColor))  \(styled(entry.source, .gray))")
            }

            // Summary
            let totalBins = entries.reduce(0) { $0 + $1.binCount }
            let totalDups = entries.filter(\.isDuplicate).count

            print()
            var summary = "\(styled("\(totalBins)", .yellow)) \(styled("executables", .dim))"
            if totalDups > 0 {
                summary += "\(styled(",", .dim)) \(styled("\(totalDups)", .orange)) \(styled("duplicates", .dim))"
            }
            print(summary)
            print(styled("Run path --help for more options.", .dim))
        }

        print()
    }

    private func printBinsTable(
        dir: String,
        rows: [(name: String, type: FileType, lang: String, detail: String)],
        home: String,
        top: Int? = nil
    ) {
        let nameW = 24
        let typeW = 12
        let langW = 10
        let tableW = 50

        let shortDir = shortPath(dir, home: home)

        print()
        print("\(styled(shortDir, .bold, .blue))  \(styled("\(rows.count)", .dim))")
        print(styled("\u{2500}".repeating(tableW), .dim))
        print("  \(styled("Name".padded(to: nameW), .lightGray))\(styled("Type".padded(to: typeW), .lightGray))\(styled("Lang", .lightGray))")

        let displayRows = top.map { Array(rows.prefix($0)) } ?? rows

        for row in displayRows {
            let typeColored = colorForType(row.type, text: row.type.rawValue).padded(to: typeW)
            let langColored = colorForLang(row.lang, text: row.lang).padded(to: langW)

            var line = "  \(row.name.padded(to: nameW))\(typeColored)\(langColored)"

            if !row.detail.isEmpty {
                if row.detail.hasPrefix("shadowed by") {
                    line += styled(row.detail, .orange)
                } else {
                    line += styled(row.detail, .gray)
                }
            }

            print(line)
        }

        if let top, rows.count > top {
            let remaining = rows.count - top
            print(styled("  ... and \(remaining) more", .dim))
        }
    }

    private func shortPath(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func expandVars(_ path: String, home: String) -> String {
        var result = path
        result = result.replacingOccurrences(of: "$HOME", with: home)
        result = result.replacingOccurrences(of: "${HOME}", with: home)
        result = result.replacingOccurrences(of: "$XDG_BIN_HOME", with: "\(home)/.local/bin")
        result = result.replacingOccurrences(of: "${XDG_BIN_HOME}", with: "\(home)/.local/bin")
        result = result.replacingOccurrences(of: "$XDG_DATA_HOME", with: "\(home)/.local/share")
        result = result.replacingOccurrences(of: "${XDG_DATA_HOME}", with: "\(home)/.local/share")
        if result.hasPrefix("~") {
            result = home + result.dropFirst()
        }
        return result
    }

    private func colorForType(_ type: FileType, text: String) -> String {
        switch type {
        case .script:    return styled(text, .cyan)
        case .container: return styled(text, .yellow)
        case .binary:    return styled(text, .red)
        }
    }

    private func colorForLang(_ lang: String, text: String) -> String {
        switch lang {
        case "shell", "bash", "zsh": return styled(text, .yellow)
        case "swift":   return styled(text, .cyan)
        case "python":  return styled(text, .green)
        case "go":      return styled(text, .blue)
        case "rust":    return styled(text, .yellow)
        case "ruby":    return styled(text, .red)
        case "node":    return styled(text, .green)
        case "perl":    return styled(text, .yellow)
        case "c":       return styled(text, .gray)
        case "objc":    return styled(text, .gray)
        case "kali":    return styled(text, .blue)
        case "debian":  return styled(text, .yellow)
        case "alpine":  return styled(text, .cyan)
        case "ubuntu":  return styled(text, .orange)
        default:        return styled(text, .gray)
        }
    }
}
