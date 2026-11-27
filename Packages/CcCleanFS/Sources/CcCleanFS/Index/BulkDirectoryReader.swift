import Foundation

/// getattrlistbulk 批量目录枚举器（基线 6.1 要点 1：单线程 3~5 万条目/秒）。
/// 属性按 bitmap set bits 升序返回；NAME 内嵌于属性（4 字节长度 + 数据，4 字节对齐）。
enum BulkDirectoryReader {

    enum BulkError: Error, Equatable {
        case openFailed(path: String, errno: Int32)
        case listFailed(path: String, errno: Int32)
    }

    /// 单个枚举条目。
    struct Entry {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let allocSize: Int64
        let logicalSize: Int64
        let mtime: Date
        let inode: UInt64
    }

    // MARK: - attrlist 构建（sys/attr.h 位定义）

    private static func makeAttrList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.reserved = 0
        // commonattr 位（升序）：RETURNED_ATTRS(bit0) NAME(bit3) OBJTYPE(bit5) MODTIME(bit10) FILEID(bit25)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FILEID)
        // fileattr 位：TOTALSIZE(bit1) ALLOCSIZE(bit2)
        list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // dirattr 位：ENTRYCOUNT(bit1)
        list.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        return list
    }

    // MARK: - 目录读取

    /// 读取一个目录的全部直接子项。
    static func readEntries(atPath path: String, bufferSize: Int = 1 << 20) throws -> [Entry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_EVTONLY)
        guard fd >= 0 else {
            throw BulkError.openFailed(path: path, errno: errno)
        }
        defer { close(fd) }

        var attrList = makeAttrList()
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        var entries: [Entry] = []
        let base = buffer

        while true {
            // options = 0：枚举全部条目（文件 + 目录）；返回值为本次填充的条目数
            let n = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if n == 0 { break }               // 目录读完
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw BulkError.listFailed(path: path, errno: e)
            }
            let count = Int(n)
            entries.reserveCapacity(entries.count + count)
            var offset = 0
            for _ in 0..<count {
                let totalLen = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                if totalLen <= 4 { break }    // 防御：长度异常则结束本轮解析
                if let entry = parseEntry(base + offset, totalLen: totalLen) {
                    entries.append(entry)
                }
                offset += totalLen
            }
        }
        return entries
    }

    // MARK: - 条目解析
    //
    // 实测布局（macOS 27 SDK，逐属性对照实验确认）：
    // [0]  totalLen (u32)
    // [4]  common 属性位图（含 RA 位）
    // [8]  vol 属性位图
    // [12] dir 属性位图
    // [16] file 属性位图
    // [20] 保留（恒 0）
    // [24] 名字数据在条目内的偏移 - 24（attr_data 语义）
    // [28] 名字 attr_length（含结尾 NUL）
    // [32] common 属性数据，按位图位序（OBJTYPE 4B / MODTIME 16B / FILEID 8B …）
    //      之后依次为 vol / dir / file 属性（按各自位图位序）
    // 末尾为名字数据（NUL 结尾）+ 4 字节对齐 padding
    private static func parseEntry(_ start: UnsafeMutableRawPointer, totalLen: Int) -> Entry? {
        let commonBits = start.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let dirBits = start.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let fileBits = start.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        let nameDataOffset = Int(start.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) + 24
        let nameLength = Int(start.loadUnaligned(fromByteOffset: 28, as: UInt32.self))

        // 名字：末尾 NUL 结尾字符串
        guard nameLength > 1, nameDataOffset > 0,
              nameDataOffset + nameLength <= totalLen else { return nil }
        let nameBytes = UnsafeRawBufferPointer(
            start: start + nameDataOffset, count: nameLength - 1   // 去掉 NUL
        )
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard !name.isEmpty, name != "." && name != ".." else { return nil }

        var offset = 32
        var objType: UInt32 = 0
        var modSeconds = 0.0
        var fileID: UInt64 = 0

        // common 属性按位序（RA 与 NAME 已单独处理）
        var common = commonBits
            & ~UInt32(ATTR_CMN_RETURNED_ATTRS)
            & ~UInt32(ATTR_CMN_NAME)
        while common != 0 {
            let bit = UInt32(common.trailingZeroBitCount)
            let mask = UInt32(1) << bit
            common &= ~mask
            switch mask {
            case UInt32(ATTR_CMN_OBJTYPE):
                objType = start.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
            case UInt32(ATTR_CMN_MODTIME):
                // struct timespec on 64-bit Darwin: tv_sec(8) + tv_nsec(8)
                let sec = start.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                modSeconds = Double(sec)
                offset += 16
            case UInt32(ATTR_CMN_FILEID):
                fileID = start.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += 8
            default:
                // 未请求的属性不会出现在流中；出现未知位则放弃该条目
                return nil
            }
        }

        let isDirectory = objType == 2      // VDIR
        let isSymlink = objType == 5        // VLNK

        // dir 属性
        if dirBits & UInt32(ATTR_DIR_ENTRYCOUNT) != 0 {
            offset += 4
        }
        // file 属性（按位序）
        var totalSize: Int64 = 0
        var allocSize: Int64 = 0
        if fileBits & UInt32(ATTR_FILE_TOTALSIZE) != 0 {
            totalSize = Int64(bitPattern: start.loadUnaligned(
                fromByteOffset: offset, as: UInt64.self))
            offset += 8
        }
        if fileBits & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
            allocSize = Int64(bitPattern: start.loadUnaligned(
                fromByteOffset: offset, as: UInt64.self))
            offset += 8
        }

        return Entry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            allocSize: allocSize,
            logicalSize: totalSize,
            mtime: Date(timeIntervalSince1970: modSeconds),
            inode: fileID
        )
    }
}
