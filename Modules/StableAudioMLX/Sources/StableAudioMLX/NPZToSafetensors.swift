import Foundation

/// Streams an uncompressed NumPy `.npz` archive (as published in
/// `stable-audio-3-optimized/MLX`) into one `.safetensors` file that MLX loads directly.
///
/// The archive is memory-mapped and each `.npy` payload is copied as is, so the
/// conversion needs no extra RAM beyond the copy buffer and no Python on the device.
/// Only little-endian C-order arrays of the dtypes below are accepted; anything else is
/// rejected rather than guessed.
public enum NPZToSafetensors {
    public enum ConversionError: Error, CustomStringConvertible {
        case notAZip
        case zip64Unsupported
        case compressedEntry(String)
        case badNPY(String)
        case unsupportedDType(String, String)
        case fortranOrder(String)

        public var description: String {
            switch self {
            case .notAZip: "not a ZIP/NPZ archive"
            case .zip64Unsupported: "ZIP64 archives are not supported"
            case .compressedEntry(let name): "\(name) is compressed; only stored NPZ entries are supported"
            case .badNPY(let name): "\(name) has an invalid .npy header"
            case .unsupportedDType(let name, let dtype): "\(name) has unsupported dtype \(dtype)"
            case .fortranOrder(let name): "\(name) is Fortran-ordered"
            }
        }
    }

    struct Tensor {
        let name: String
        let dtype: String
        let shape: [Int]
        let dataRange: Range<Int>
    }

    /// Converts `source` to `destination`. Entries whose name is in `skipping` (without
    /// `.npy`), or that do not start with `onlyPrefix`, are left out. Returns the number
    /// of tensors written.
    @discardableResult
    public static func convert(
        source: URL, destination: URL,
        skipping: Set<String> = ["TOKENIZER_MODEL"],
        onlyPrefix: String? = nil
    ) throws -> Int {
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        let tensors = try readTensors(data).filter {
            !skipping.contains($0.name) && (onlyPrefix.map($0.name.hasPrefix) ?? true)
        }

        var header: [String: Any] = [:]
        var offset = 0
        for tensor in tensors {
            let length = tensor.dataRange.count
            header[tensor.name] = [
                "dtype": tensor.dtype,
                "shape": tensor.shape,
                "data_offsets": [offset, offset + length],
            ] as [String: Any]
            offset += length
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }

        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        do {
            var length = UInt64(json.count).littleEndian
            try handle.write(contentsOf: Data(bytes: &length, count: 8))
            try handle.write(contentsOf: json)
            let chunk = 8 << 20
            for tensor in tensors {
                var start = tensor.dataRange.lowerBound
                while start < tensor.dataRange.upperBound {
                    let end = min(start + chunk, tensor.dataRange.upperBound)
                    try autoreleasepool {
                        try handle.write(contentsOf: data.subdata(in: start ..< end))
                    }
                    start = end
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return tensors.count
    }

    // MARK: - ZIP central directory

    static func readTensors(_ data: Data) throws -> [Tensor] {
        // End of central directory record: signature 0x06054b50 within the last 64 KiB.
        let eocdSignature: UInt32 = 0x0605_4B50
        let searchStart = max(0, data.count - 65_557)
        var eocd = -1
        var index = data.count - 22
        while index >= searchStart {
            if data.uint32(at: index) == eocdSignature { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ConversionError.notAZip }
        let entryCount = Int(data.uint16(at: eocd + 10))
        let directoryOffset = Int(data.uint32(at: eocd + 16))
        guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw ConversionError.zip64Unsupported }

        var tensors: [Tensor] = []
        var cursor = directoryOffset
        for _ in 0 ..< entryCount {
            guard data.uint32(at: cursor) == 0x0201_4B50 else { throw ConversionError.notAZip }
            let method = data.uint16(at: cursor + 10)
            let compressedSize = Int(data.uint32(at: cursor + 20))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let localOffset = Int(data.uint32(at: cursor + 42))
            let nameData = data.subdata(in: (cursor + 46) ..< (cursor + 46 + nameLength))
            let fileName = String(decoding: nameData, as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard compressedSize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw ConversionError.zip64Unsupported }
            guard method == 0 else { throw ConversionError.compressedEntry(fileName) }
            guard data.uint32(at: localOffset) == 0x0403_4B50 else { throw ConversionError.notAZip }
            let localNameLength = Int(data.uint16(at: localOffset + 26))
            let localExtraLength = Int(data.uint16(at: localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            let name = fileName.hasSuffix(".npy") ? String(fileName.dropLast(4)) : fileName
            tensors.append(try parseNPY(data, name: name, payload: payloadStart ..< (payloadStart + compressedSize)))
        }
        return tensors
    }

    // MARK: - .npy header

    static let dtypes: [String: (safetensors: String, bytes: Int)] = [
        "<f2": ("F16", 2), "<f4": ("F32", 4), "<f8": ("F64", 8),
        "<i4": ("I32", 4), "<i8": ("I64", 8), "<u4": ("U32", 4),
        "|u1": ("U8", 1), "|i1": ("I8", 1), "|b1": ("BOOL", 1),
    ]

    static func parseNPY(_ data: Data, name: String, payload: Range<Int>) throws -> Tensor {
        let base = payload.lowerBound
        guard payload.count >= 10, data[base] == 0x93,
              String(decoding: data.subdata(in: (base + 1) ..< (base + 6)), as: UTF8.self) == "NUMPY"
        else { throw ConversionError.badNPY(name) }
        let major = data[base + 6]
        let headerLength: Int
        let headerStart: Int
        if major == 1 {
            headerLength = Int(data.uint16(at: base + 8))
            headerStart = base + 10
        } else {
            headerLength = Int(data.uint32(at: base + 8))
            headerStart = base + 12
        }
        let header = String(decoding: data.subdata(in: headerStart ..< (headerStart + headerLength)), as: UTF8.self)
        guard let descr = capture(header, key: "descr", open: "'", close: "'") else { throw ConversionError.badNPY(name) }
        guard let dtype = dtypes[descr] else { throw ConversionError.unsupportedDType(name, descr) }
        if header.contains("'fortran_order': True") { throw ConversionError.fortranOrder(name) }
        guard let shapeText = capture(header, key: "shape", open: "(", close: ")") else { throw ConversionError.badNPY(name) }
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let dataStart = headerStart + headerLength
        let expected = shape.reduce(1, *) * dtype.bytes
        guard payload.upperBound - dataStart == expected else { throw ConversionError.badNPY(name) }
        return Tensor(name: name, dtype: dtype.safetensors, shape: shape, dataRange: dataStart ..< payload.upperBound)
    }

    private static func capture(_ header: String, key: String, open: Character, close: Character) -> String? {
        guard let keyRange = header.range(of: "'\(key)':") else { return nil }
        let rest = header[keyRange.upperBound...]
        guard let start = rest.firstIndex(of: open) else { return nil }
        let afterOpen = rest.index(after: start)
        guard let end = rest[afterOpen...].firstIndex(of: close) else { return nil }
        return String(rest[afterOpen ..< end])
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
