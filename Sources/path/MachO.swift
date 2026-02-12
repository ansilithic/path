import Foundation

enum MachO {
    // Mach-O magic numbers
    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let MH_CIGAM_64: UInt32 = 0xCFFAEDFE
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_CIGAM: UInt32 = 0xBEBAFECA

    // Load command types
    private static let LC_SEGMENT_64: UInt32 = 0x19

    static func detectLanguage(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        guard let magicData = readBytes(handle, count: 4, at: 0) else { return nil }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }

        switch magic {
        case MH_MAGIC_64:
            return parseMachO64(handle, offset: 0, swap: false)
        case MH_CIGAM_64:
            return parseMachO64(handle, offset: 0, swap: true)
        case FAT_MAGIC:
            return parseFat(handle, swap: false)
        case FAT_CIGAM:
            return parseFat(handle, swap: true)
        default:
            return nil
        }
    }

    private static func parseFat(_ handle: FileHandle, swap: Bool) -> String? {
        guard let countData = readBytes(handle, count: 4, at: 4) else { return nil }
        var nArch = countData.withUnsafeBytes { $0.load(as: UInt32.self) }
        if swap { nArch = nArch.byteSwapped }
        guard nArch > 0 else { return nil }

        guard let archData = readBytes(handle, count: 12, at: 8) else { return nil }
        let offset = archData.withUnsafeBytes {
            var val = $0.load(fromByteOffset: 8, as: UInt32.self)
            if swap { val = val.byteSwapped }
            return UInt64(val)
        }

        guard let sliceMagic = readBytes(handle, count: 4, at: offset) else { return nil }
        let magic = sliceMagic.withUnsafeBytes { $0.load(as: UInt32.self) }

        switch magic {
        case MH_MAGIC_64:
            return parseMachO64(handle, offset: offset, swap: false)
        case MH_CIGAM_64:
            return parseMachO64(handle, offset: offset, swap: true)
        default:
            return nil
        }
    }

    private static func parseMachO64(_ handle: FileHandle, offset: UInt64, swap: Bool) -> String? {
        guard let headerData = readBytes(handle, count: 32, at: offset) else { return nil }

        var ncmds = headerData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        if swap { ncmds = ncmds.byteSwapped }

        var cmdOffset = offset + 32
        var foundSections = Set<String>()

        for _ in 0..<ncmds {
            guard let cmdHeader = readBytes(handle, count: 8, at: cmdOffset) else { break }
            var cmd = cmdHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            var cmdSize = cmdHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            if swap { cmd = cmd.byteSwapped; cmdSize = cmdSize.byteSwapped }

            if cmd == LC_SEGMENT_64 {
                guard let segData = readBytes(handle, count: 72, at: cmdOffset) else { break }

                var nsects = segData.withUnsafeBytes { $0.load(fromByteOffset: 64, as: UInt32.self) }
                if swap { nsects = nsects.byteSwapped }

                var sectOffset = cmdOffset + 72
                for _ in 0..<nsects {
                    guard let sectData = readBytes(handle, count: 80, at: sectOffset) else { break }
                    let sectName = sectData.withUnsafeBytes { buf -> String in
                        let ptr = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
                        return String(cString: ptr)
                    }
                    foundSections.insert(sectName)
                    sectOffset += 80
                }
            }

            cmdOffset += UInt64(cmdSize)
        }

        if foundSections.contains(where: { $0.hasPrefix("__swift5") }) {
            return "swift"
        } else if foundSections.contains("__go_buildinfo") {
            return "go"
        } else if foundSections.contains(where: { $0.hasPrefix("__rustc") }) {
            return "rust"
        } else if foundSections.contains(where: { $0.hasPrefix("__objc") }) {
            return "objc"
        } else {
            return "c"
        }
    }

    private static func readBytes(_ handle: FileHandle, count: Int, at offset: UInt64) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
