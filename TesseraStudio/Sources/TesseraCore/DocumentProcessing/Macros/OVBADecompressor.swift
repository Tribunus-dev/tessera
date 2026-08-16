import Foundation

// MARK: - OVBADecompressorError

/// Thrown by ``OVBADecompressor/decompress(_:)`` when the input does not
/// conform to the [MS-OVBA] `CompressedContainer` structure (2.4.1). Every
/// malformed-input path throws one of these rather than crashing, trapping,
/// or silently producing truncated/garbage output.
public enum OVBADecompressorError: Error, Equatable, Sendable {
    /// The container was empty; a valid `CompressedContainer` needs at
    /// least the 1-byte signature.
    case emptyContainer
    /// `CompressedContainerSignature` (byte 0) was not `0x01`.
    case invalidSignature(found: UInt8)
    /// Fewer than 2 bytes remained for a `CompressedChunkHeader`.
    case truncatedChunkHeader(atOffset: Int)
    /// `CompressedChunkSignature` (header bits 12-14) was not `0b011`.
    case invalidChunkSignature(found: UInt8, atOffset: Int)
    /// The chunk's declared on-wire size runs past the end of the input.
    case truncatedChunkData(atOffset: Int)
    /// An uncompressed (raw) chunk did not have the full 4096 bytes of
    /// literal data it must carry.
    case truncatedRawChunk(atOffset: Int)
    /// A `TokenSequence` flag byte was read past the chunk's own end.
    case truncatedFlagByte(atOffset: Int)
    /// A literal token's byte was read past the chunk's own end.
    case truncatedLiteralToken(atOffset: Int)
    /// A copy token's 2 bytes were read past the chunk's own end.
    case truncatedCopyToken(atOffset: Int)
    /// A copy token's computed back-reference offset pointed before the
    /// start of the CURRENT chunk's own decompressed output (chunks never
    /// reference across chunk boundaries) - an impossible back-reference,
    /// meaning the input is not a well-formed `CompressedContainer`.
    case copyTokenOffsetOutOfRange(offset: Int, atOffset: Int)
}

// MARK: - OVBADecompressor

/// Decompresses [MS-OVBA] `CompressedContainer` byte streams - the format
/// a `vbaProject.bin` module's `SourceCode` (and `dir`) stream data is
/// stored in, inside the OLE/CFBF compound file MS-OVBA 2.13's own design
/// position calls out (2.3.4.3 "Module Stream"). This is NOT zip/gzip: a
/// bespoke chunk-based scheme (2.4.1) the SOTA report's own text calls
/// "RLE" - each up-to-4096-byte decompressed chunk is a sequence of
/// 8-token groups, one flag byte per group, each token either a literal
/// byte or a back-reference `(offset, length)` copy into the CURRENT
/// chunk's own already-decompressed output, copied byte by byte (so an
/// offset smaller than length is legal and behaves like run-length
/// repetition - the "RLE" shape the design contract's own text is
/// describing, even though the underlying scheme is closer to LZ77).
///
/// Pure: no file I/O, no shared mutable state, no OLE/CFBF parsing of its
/// own (`MacroCompatLayer` is the caller that locates a module's
/// `CompressedContainer` bytes inside the compound file first). Every
/// malformed-input path throws ``OVBADecompressorError`` rather than
/// trapping or producing garbage output silently - the design contract's
/// own "throwing on malformed input rather than crashing" requirement.
public enum OVBADecompressor {

    /// Decompresses one MS-OVBA `CompressedContainer` (a single module's
    /// source bytes, already isolated from the OLE compound file and its
    /// own `PerformanceCache` prefix - see `MacroCompatLayer`) into the
    /// UTF-8-ish module source text bytes it represents.
    public static func decompress(_ compressed: Data) throws -> Data {
        let bytes = [UInt8](compressed)
        guard !bytes.isEmpty else { throw OVBADecompressorError.emptyContainer }
        guard bytes[0] == 0x01 else {
            throw OVBADecompressorError.invalidSignature(found: bytes[0])
        }

        var output = [UInt8]()
        var offset = 1

        while offset < bytes.count {
            guard offset + 2 <= bytes.count else {
                throw OVBADecompressorError.truncatedChunkHeader(atOffset: offset)
            }
            let chunkHeaderOffset = offset
            let header = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2

            // CompressedChunkSignature: header bits 12-14, MUST be 0b011.
            let chunkSignature = UInt8((header >> 12) & 0x7)
            guard chunkSignature == 0b011 else {
                throw OVBADecompressorError.invalidChunkSignature(found: chunkSignature, atOffset: chunkHeaderOffset)
            }
            // CompressedChunkFlag: header bit 15. 1 = compressed (tokens),
            // 0 = raw (the next 4096 bytes copied literally).
            let isCompressed = (header & 0x8000) != 0
            // CompressedChunkSize: header bits 0-11. The on-wire size of
            // the WHOLE chunk (header included) is this value plus 3.
            let chunkSize = Int(header & 0x0FFF) + 3
            let chunkEnd = chunkHeaderOffset + chunkSize
            guard chunkEnd <= bytes.count else {
                throw OVBADecompressorError.truncatedChunkData(atOffset: chunkHeaderOffset)
            }

            if !isCompressed {
                guard offset + 4096 <= bytes.count, offset + 4096 <= chunkEnd else {
                    throw OVBADecompressorError.truncatedRawChunk(atOffset: offset)
                }
                output.append(contentsOf: bytes[offset..<(offset + 4096)])
                offset = chunkEnd
                continue
            }

            let chunkOutputStart = output.count
            while offset < chunkEnd {
                let flagByte = bytes[offset]
                offset += 1
                for bitIndex in 0..<8 {
                    if offset >= chunkEnd { break }
                    let isCopyToken = ((flagByte >> bitIndex) & 0x1) == 1
                    if !isCopyToken {
                        guard offset < bytes.count else {
                            throw OVBADecompressorError.truncatedLiteralToken(atOffset: offset)
                        }
                        output.append(bytes[offset])
                        offset += 1
                    } else {
                        guard offset + 2 <= bytes.count else {
                            throw OVBADecompressorError.truncatedCopyToken(atOffset: offset)
                        }
                        let tokenOffset = offset
                        let token = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                        offset += 2

                        // [MS-OVBA] 2.4.1.3.19 "CopyToken Help": bit width
                        // depends on how many bytes this CHUNK (not the
                        // whole container) has decompressed so far.
                        let differenceValue = output.count - chunkOutputStart
                        let bitCount = Self.bitCount(forDifferenceValue: differenceValue)
                        let lengthMask = UInt16(0xFFFF >> bitCount)
                        let offsetMask = ~lengthMask
                        let length = Int(token & lengthMask) + 3
                        let temp1 = token & offsetMask
                        let shiftAmount = 16 - bitCount
                        let backOffset = (Int(temp1) >> shiftAmount) + 1

                        guard backOffset <= differenceValue else {
                            throw OVBADecompressorError.copyTokenOffsetOutOfRange(offset: backOffset, atOffset: tokenOffset)
                        }
                        // Byte-by-byte, not a bulk copy: an offset smaller
                        // than length legally repeats bytes this same
                        // token already produced (the "RLE" shape).
                        for _ in 0..<length {
                            output.append(output[output.count - backOffset])
                        }
                    }
                }
            }
            offset = chunkEnd
        }

        return Data(output)
    }

    /// [MS-OVBA] 2.4.1.3.19 "CopyToken Help": the smallest bit count in
    /// `4...15` such that `2^bitCount >= differenceValue` (the count of
    /// bytes already decompressed within the CURRENT chunk, before this
    /// token is applied). A loop over the fixed 4...15 range (rather than
    /// `log2`) sidesteps floating-point rounding at exact powers of two.
    static func bitCount(forDifferenceValue differenceValue: Int) -> Int {
        var bitCount = 4
        while bitCount < 15 && (1 << bitCount) < differenceValue {
            bitCount += 1
        }
        return bitCount
    }
}
