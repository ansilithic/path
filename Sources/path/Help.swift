import CLICore

enum Help {
    struct Entry {
        let name: String
        let args: String
        let description: String
        let tag: String?

        var labelWidth: Int {
            args.isEmpty ? name.count : name.count + 1 + args.count
        }
    }

    struct FilterGroup {
        let title: String
        let entries: [Entry]
    }

    static let modeGroups: [FilterGroup] = [
        FilterGroup(title: "Display", entries: [
            Entry(name: "-l, --list", args: "", description: "List all executables in PATH", tag: nil),
            Entry(name: "-s, --shadows", args: "", description: "Show shadowed executables (implies --list)", tag: nil),
        ]),
        FilterGroup(title: "Filters", entries: [
            Entry(name: "--dir", args: "<path>", description: "Filter to a specific directory", tag: nil),
        ]),
    ]

    static let options: [Entry] = [
        Entry(name: "-h, --help", args: "", description: "Show help information", tag: nil),
        Entry(name: "--version", args: "", description: "Show the version", tag: nil),
    ]

    static func print() {
        let allEntries = modeGroups.flatMap(\.entries) + options
        let labelWidth = allEntries.map(\.labelWidth).max()! + 3

        Swift.print()
        Swift.print("  \(styled("path", .bold, .white))  \(styled("Inspect PATH entries, sources, and executables.", .dim))")
        Swift.print()
        Swift.print("  \(styled("Usage", .bold))  \(styled("path", .white)) \(styled("[options]", .dim))")
        Swift.print()
        printFilterSections(labelWidth: labelWidth)
        printSection("Options", options, labelWidth: labelWidth)
    }

    private static func styledLabel(_ entry: Entry, paddedTo width: Int) -> String {
        if entry.args.isEmpty {
            return styled(entry.name, .cyan).padded(to: width)
        }
        return (styled(entry.name, .cyan) + " " + styled(entry.args, .dim)).padded(to: width)
    }

    private static func printFilterSections(labelWidth: Int) {
        for group in modeGroups {
            Swift.print("  \(styled(group.title, .bold))")
            Swift.print()
            for entry in group.entries {
                let label = styledLabel(entry, paddedTo: labelWidth)
                let desc = styled(entry.description, .white)
                let tag = entry.tag.map { " " + styled("(\($0))", .dim) } ?? ""
                Swift.print("    \(label)\(desc)\(tag)")
            }
            Swift.print()
        }
    }

    private static func printSection(_ title: String, _ entries: [Entry], labelWidth: Int) {
        Swift.print("  \(styled(title, .bold))")
        Swift.print()
        for entry in entries {
            let label = styledLabel(entry, paddedTo: labelWidth)
            let desc = styled(entry.description, .white)
            let tag = entry.tag.map { " " + styled("(\($0))", .dim) } ?? ""
            Swift.print("    \(label)\(desc)\(tag)")
        }
        Swift.print()
    }
}
