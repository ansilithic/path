import ArgumentParser
import CLICore
import Foundation

@main
struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Display PATH entries with sources and analysis.",
        version: "1.0.0"
    )

    @Flag(name: [.customShort("d"), .long], help: "Show only duplicate entries")
    var dupes = false

    func run() {
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

        for rc in rcFiles {
            guard let contents = try? String(contentsOfFile: rc, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
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
            let isRootOwned: Bool
            let source: String
        }

        var seen = Set<String>()
        var entries: [Entry] = []

        for (i, p) in pathEntries.enumerated() {
            let isDup = seen.contains(p)
            seen.insert(p)

            var exists = false
            var binCount = 0
            var isRoot = false

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                exists = true
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
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   let ownerID = attrs[.ownerAccountID] as? NSNumber {
                    isRoot = ownerID.intValue == 0
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
                isRootOwned: isRoot,
                source: sourceDisplay
            ))
        }

        // Filter if --dupes
        let displayEntries = dupes ? entries.filter(\.isDuplicate) : entries

        // Calculate max path length for alignment
        let maxPathLen = displayEntries.map(\.path.count).max() ?? 40

        // Header
        print()
        print("\(styled("PATH", .bold, .cyan)) \(styled("\(pathEntries.count) entries", .dim))")
        print()

        // Table header
        let headerPath = "Directory".padding(toLength: maxPathLen, withPad: " ", startingAt: 0)
        print(styled("  #  \(headerPath)   Bins  Source", .lightGray))

        // Entries
        for entry in displayEntries {
            // Path color
            let pathColor: Color
            if !entry.exists {
                pathColor = .red
            } else if entry.path.contains("/homebrew/") || entry.path.contains("/Homebrew/") {
                pathColor = .cyan
            } else if !entry.isRootOwned {
                pathColor = .magenta
            } else {
                pathColor = .green
            }

            // Index color
            let idxColor: Color = entry.isDuplicate ? .orange : .gray

            let paddedPath = entry.path.padding(toLength: maxPathLen, withPad: " ", startingAt: 0)
            let binStr = String(entry.binCount).padding(toLength: 5, withPad: " ", startingAt: 0)

            print(" \(styled(String(format: "%2d", entry.index), idxColor))  \(styled(paddedPath, pathColor))  \(styled(binStr, .yellow))  \(styled(entry.source, .gray))")
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
        print()
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
}
