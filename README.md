# pathfinder

Display PATH entries with their source files, executable counts, and ownership analysis.

## Install

```sh
brew tap ansilithic/tap
brew install pathfinder
```

Or build from source:

```sh
make build && make install
```

## Usage

```
USAGE: path [--dupes]

OPTIONS:
  -d, --dupes   Show only duplicate entries
  --version     Show the version.
  -h, --help    Show help information.
```

### Examples

```sh
path            # Show all PATH entries with sources
path --dupes    # Show only duplicate PATH entries
```

## Output

Each PATH entry is color-coded:

| Color | Meaning |
|-------|---------|
| Green | Root-owned system path |
| Cyan | Homebrew path |
| Magenta | User-owned path |
| Red | Missing path (directory doesn't exist) |

Source files are traced from `/etc/paths`, `/etc/paths.d/`, and shell RC files (`.zshrc`, `.bashrc`, etc.).

## Requirements

- macOS 14+ (Sonoma)
- Swift 6.0

## License

MIT
