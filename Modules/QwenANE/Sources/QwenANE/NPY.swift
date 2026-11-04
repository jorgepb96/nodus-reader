import Foundation
import Accelerate

/// Read-only memory-mapped .npy (C order). Mapped pages are clean file pages, so
/// the 150 MB text-embedding table costs nothing until rows are touched.
final class NPY {
    let shape: [Int]
    let descr: String
    private let base: UnsafeRawPointer
    private let mapLen: Int
    private let mapBase: UnsafeMutableRawPointer
    let data: UnsafeRawPointer

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw QwenANEError.invalid("cannot open \(path)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { throw QwenANEError.invalid("empty or unreadable \(path)") }
        mapLen = Int(st.st_size)
        guard let m = mmap(nil, mapLen, PROT_READ, MAP_PRIVATE, fd, 0), m != MAP_FAILED else {
            throw QwenANEError.invalid("mmap failed for \(path)")
        }
        let parsed: (descr: String, shape: [Int], dataOffset: Int)
        do { parsed = try Self.parseHeader(UnsafeRawPointer(m), mapLen: mapLen, path: path) }
        catch { munmap(m, mapLen); throw error }
        mapBase = m
        base = UnsafeRawPointer(m)
        descr = parsed.descr
        shape = parsed.shape
        data = base + parsed.dataOffset
    }

    /// Validates the header against the mapped length; every failure is a throw, never a trap.
    private static func parseHeader(_ base: UnsafeRawPointer, mapLen: Int, path: String) throws -> (descr: String, shape: [Int], dataOffset: Int) {
        let b = base.assumingMemoryBound(to: UInt8.self)
        guard mapLen > 12, b[0] == 0x93, String(bytes: [b[1], b[2], b[3], b[4], b[5]], encoding: .ascii) == "NUMPY" else {
            throw QwenANEError.invalid("not an npy file: \(path)")
        }
        let major = b[6]
        var hlen = 0, off = 0
        if major == 1 { hlen = Int(b[8]) | Int(b[9]) << 8; off = 10 }
        else { hlen = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24; off = 12 }
        guard hlen > 0, off + hlen <= mapLen else { throw QwenANEError.invalid("npy header out of range: \(path)") }
        let header = String(decoding: UnsafeBufferPointer(start: b + off, count: hlen), as: UTF8.self)
        guard !header.contains("'fortran_order': True") else { throw QwenANEError.invalid("fortran order unsupported") }
        guard let dr = header.range(of: "'descr': '") else { throw QwenANEError.invalid("npy header: no descr") }
        let rest = header[dr.upperBound...]
        guard let dEnd = rest.firstIndex(of: "'") else { throw QwenANEError.invalid("npy header: unterminated descr") }
        let descr = String(rest[..<dEnd])
        guard let sr = header.range(of: "'shape': (") else { throw QwenANEError.invalid("npy header: no shape") }
        let srest = header[sr.upperBound...]
        guard let sEnd = srest.firstIndex(of: ")") else { throw QwenANEError.invalid("npy header: unterminated shape") }
        let shape = srest[..<sEnd].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard shape.allSatisfy({ $0 >= 0 }) else { throw QwenANEError.invalid("npy header: negative dimension") }
        let elem = descr.hasSuffix("1") ? 1 : descr.hasSuffix("2") ? 2 : descr.hasSuffix("8") ? 8 : 4
        var bytes = elem
        for d in shape {
            let r = bytes.multipliedReportingOverflow(by: d)
            guard !r.overflow else { throw QwenANEError.invalid("npy shape overflows: \(path)") }
            bytes = r.partialValue
        }
        guard off + hlen + bytes <= mapLen else { throw QwenANEError.invalid("npy truncated: \(path)") }
        return (descr, shape, off + hlen)
    }

    var count: Int { shape.reduce(1, *) }
    var f32: UnsafePointer<Float> { precondition(descr == "<f4"); return data.assumingMemoryBound(to: Float.self) }
    var u32: UnsafePointer<UInt32> { precondition(descr == "<u4"); return data.assumingMemoryBound(to: UInt32.self) }
    /// fp16 elements as raw IEEE half bits (UInt16, not Float16: Float16 doesn't exist for x86_64 macOS
    /// slices, which Xcode still compiles for package targets).
    var f16: UnsafePointer<UInt16> { precondition(descr == "<f2"); return data.assumingMemoryBound(to: UInt16.self) }
    var isHalf: Bool { descr == "<f2" }
    /// Element `i` as fp32, whether the file stores fp32 or fp16.
    @inline(__always) func float(at i: Int) -> Float { isHalf ? halfBitsToFloat(f16[i]) : f32[i] }
    /// Copies `n` elements starting at `start` into `dst` as fp32 (fp16 files are widened).
    func copyFloats(from start: Int, count n: Int, to dst: UnsafeMutablePointer<Float>) {
        if isHalf { widenHalf(f16 + start, dst, n) } else { memcpy(dst, f32 + start, n * 4) }
    }
    var i32: UnsafePointer<Int32> { precondition(descr == "<i4"); return data.assumingMemoryBound(to: Int32.self) }
    var i64: UnsafePointer<Int64> { precondition(descr == "<i8"); return data.assumingMemoryBound(to: Int64.self) }

    deinit { munmap(mapBase, mapLen) }
}

/// fp16 -> fp32 (vImage; fast in debug builds too).
func widenHalf(_ src: UnsafePointer<UInt16>, _ dst: UnsafeMutablePointer<Float>, _ n: Int) {
    var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
    var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst), height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
    vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
}

/// IEEE 754 half (as bits) -> Float, exact for every value including subnormals, inf and NaN.
@inline(__always) func halfBitsToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp = Int((h >> 10) & 0x1F), man = UInt32(h & 0x3FF)
    if exp == 0 {
        if man == 0 { return Float(bitPattern: sign) }
        return (sign != 0 ? -1 : 1) * Float(man) * 0x1p-24             // subnormal: man * 2^-24
    }
    if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (man << 13)) }
    return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | (man << 13))
}
