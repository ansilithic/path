# path

![Swift 6.0](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)

Inspect PATH entries — where each directory came from, what executables it contains, and what's shadowing what.

![path](assets/screenshot.png)

## How it works

path reads the current `PATH` environment variable and traces each directory back to its source file (`/etc/paths`, `/etc/paths.d/*`, shell RC files, or eval patterns like `brew shellenv`). It shows executable counts per directory, flags ghost (nonexistent) directories, and identifies writable entries.

In list mode, every executable is classified as a script or binary. Binaries are identified by language (Swift, Go, Rust, C, Objective-C) by reading Mach-O headers directly. Scripts are identified by shebang. Symlink targets are resolved and displayed.

Shadows mode finds executables with the same name across multiple PATH directories — the earlier entry wins, and later duplicates are flagged.

## Install

```sh
brew install ansilithic/tap/path
```

Or build from source (requires Xcode and macOS 14+):

```sh
make build && make install
```

## Usage

```
USAGE: path [--list] [--shadows] [--dir <path>]

OPTIONS:
  -l, --list              List executables in each directory
  -s, --shadows           Show only shadowed executables (implies --list)
  --dir <path>            Filter to a specific directory
  --version               Show the version
  -h, --help              Show help information
```

### Examples

```sh
path                     # Show all PATH entries with sources and executable counts
path --list              # List every executable with type and language classification
path --shadows           # Find shadowed executables across PATH directories
path --dir /usr/local/bin  # Inspect a single directory
```

## License

MIT
