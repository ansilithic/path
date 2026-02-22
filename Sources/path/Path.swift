import ArgumentParser
import CLICore
import Foundation

@main
struct PathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Inspect PATH entries, sources, and executables.",
        version: "2.0.0"
    )

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let wantsHelp = args.contains("-h") || args.contains("--help")
        let wantsVersion = args.contains("--version")

        if wantsHelp {
            Help.print()
            return
        }

        if wantsVersion {
            print(configuration.version)
            return
        }

        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    @Flag(name: [.customShort("l"), .long], help: "List executables in each directory")
    var list = false

    @Flag(name: [.customShort("s"), .long], help: "Show only shadowed executables (implies --list)")
    var shadows = false

    @Option(name: [.long], help: "Filter to a specific directory")
    var dir: String?

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

        var displayEntries = entries

        // Filter if --dir
        if let dirFilter = dir {
            displayEntries = displayEntries.filter { $0.path.hasSuffix(dirFilter) || $0.path == dirFilter }
        }

        // Track shadowed names across all directories
        var seenNames: [String: String] = [:]

        if list {
            // --list mode: unified executable table

            struct ExecRow {
                let dirPath: String
                let name: String
                let type: FileType
                let lang: String
                let detail: String
                let isShadowed: Bool
            }

            var allRows: [ExecRow] = []
            var missingEntries: [Entry] = []
            var totalExecs = 0
            var scriptCount = 0
            var binaryCount = 0
            var shadowedCount = 0

            for entry in displayEntries {
                guard entry.exists else {
                    missingEntries.append(entry)
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

                for (name, classification, symlinkDetail) in results {
                    var detail = symlinkDetail
                    var isShadowed = false
                    if let firstDir = seenNames[name] {
                        let shortened = shortPath(firstDir, home: home)
                        detail = "shadowed by \(shortened)"
                        isShadowed = true
                    } else {
                        seenNames[name] = entry.path
                    }

                    allRows.append(ExecRow(
                        dirPath: entry.path,
                        name: name,
                        type: classification.type,
                        lang: classification.lang,
                        detail: detail,
                        isShadowed: isShadowed
                    ))

                    totalExecs += 1
                    switch classification.type {
                    case .script: scriptCount += 1
                    case .binary: binaryCount += 1
                    }
                    if isShadowed { shadowedCount += 1 }
                }
            }

            var displayRows = allRows

            // Apply --shadows filter
            if shadows {
                displayRows = displayRows.filter(\.isShadowed)
            }

            if displayRows.isEmpty && shadows {
                print("\nNo shadowed executables found.")
            } else if !displayRows.isEmpty {
                let table = TrafficLightTable(segments: [
                    .indicators([
                        Indicator("binary", color: .red),
                        Indicator("script", color: .cyan),
                        Indicator("shadowed", color: .orange),
                    ]),
                    .column(TextColumn("Executable", sizing: .auto())),
                    .column(TextColumn("Lang", sizing: .auto())),
                    .column(TextColumn("", sizing: .flexible(minWidth: 0))),
                ])

                var tableRows: [TrafficLightRow] = []
                for row in displayRows {
                    let dir = shortPath(row.dirPath, home: home)
                    let merged = styled(dir + "/", .darkGray) + row.name

                    let detail: String
                    if row.detail.isEmpty {
                        detail = ""
                    } else if row.isShadowed {
                        detail = styled(row.detail, .orange)
                    } else {
                        detail = styled(row.detail, .gray)
                    }

                    tableRows.append(TrafficLightRow(
                        indicators: [[
                            row.type == .binary ? .on : .off,
                            row.type == .script ? .on : .off,
                            row.isShadowed ? .on : .off,
                        ]],
                        values: [
                            merged,
                            colorForLang(row.lang, text: row.lang),
                            detail,
                        ]
                    ))
                }

                let counts: [[Int]] = [[binaryCount, scriptCount, shadowedCount]]
                print(table.render(rows: tableRows, counts: counts), terminator: "")
            }

            // Ghost directories
            for entry in missingEntries {
                print("\(styled("●", .red))  \(styled(shortPath(entry.path, home: home), .bold, .red))  \(styled("ghost", .red))  \(styled("(\(entry.source))", .gray))")
            }
        } else {
            // Default mode: directory summary table
            let table = TrafficLightTable(segments: [
                .indicators([
                    Indicator("ghost (nonexistent directory)", color: .red),
                    Indicator("writable", color: .blue),
                ]),
                .column(TextColumn("Directory", sizing: .auto())),
                .column(TextColumn("Executables", sizing: .fixed(12))),
                .column(TextColumn("Source", sizing: .flexible(minWidth: 10))),
            ])

            var rows: [TrafficLightRow] = []
            for entry in displayEntries {
                rows.append(TrafficLightRow(
                    indicators: [[
                        entry.exists ? .off : .on,
                        entry.writable ? .on : .off,
                    ]],
                    values: [
                        entry.exists
                            ? "\(Self.neonGreen)\(entry.path)\(Color.reset.rawValue)"
                            : styled(entry.path, .red, .dim),
                        entry.exists ? styled(String(entry.binCount), .yellow) : styled("\u{2014}", .dim),
                        styled(entry.source, .gray),
                    ]
                ))
            }

            let counts: [[Int]] = [[
                entries.filter { !$0.exists }.count,
                entries.filter(\.writable).count,
            ]]

            print(table.render(rows: rows, counts: counts), terminator: "")
        }

        print()
    }

    private static let neonGreen = "\u{1B}[38;2;47;255;18m"

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
        default:        return styled(text, .gray)
        }
    }
}
