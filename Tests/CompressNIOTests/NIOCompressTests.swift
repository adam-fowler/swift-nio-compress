@testable import CompressNIO
import NIOCore
import XCTest

class CompressNIOTests: XCTestCase {
    // create consistent buffer of random values. Will always create the same given you supply the same z and w values
    // Random number generator from https://www.codeproject.com/Articles/25172/Simple-Random-Number-Generation
    func createConsistentRandomBuffer(_ w: UInt, _ z: UInt, size: Int, randomness: Int = 100) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        var z = z
        var w = w
        func getUInt16() -> UInt16 {
            z = 36969 * (z & 65535) + (z >> 16)
            w = 18000 * (w & 65535) + (w >> 16)
            return UInt16(((z << 16) + w) & 0xFFFF)
        }
        let limit = (randomness * 65536) / 100
        for i in 0..<size {
            let random = getUInt16()
            if random < limit {
                buffer.writeInteger(UInt8(random & 0xFF))
            } else {
                buffer.writeInteger(UInt8(i & 0xFF))
            }
        }
        return buffer
    }

    /// Create random buffer
    /// - Parameters:
    ///   - size: size of buffer
    ///   - randomness: how random you want the buffer to be (percentage)
    func createRandomBuffer(size: Int, randomness: Int = 100) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        let randomness = (randomness * randomness) / 100
        for i in 0..<size {
            let random = Int.random(in: 0..<25600)
            if random < randomness * 256 {
                buffer.writeInteger(UInt8(random & 0xFF))
            } else {
                buffer.writeInteger(UInt8(i & 0xFF))
            }
        }
        return buffer
    }

    func testCompressDecompress(_ algorithm: CompressionAlgorithm, bufferSize: Int = 16000) throws {
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 50)
        var bufferToCompress = buffer
        var compressedBuffer = try bufferToCompress.compress(with: algorithm, allocator: ByteBufferAllocator())
        var uncompressedBuffer = ByteBufferAllocator().buffer(capacity: bufferSize)
        try compressedBuffer.decompress(to: &uncompressedBuffer, with: algorithm)
        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func streamCompress(_ algorithm: CompressionAlgorithm, buffer: inout ByteBuffer, blockSize: Int = 1024) throws -> ByteBuffer {
        // compress
        let compressor = algorithm.compressor
        try compressor.startStream()
        var compressedBuffer = ByteBufferAllocator().buffer(capacity: buffer.readableBytes)

        while buffer.readableBytes > 0 {
            let size = min(blockSize, buffer.readableBytes)
            var slice = buffer.readSlice(length: size)!
            var compressedSlice = try slice.compressStream(with: compressor, flush: .no)
            compressedBuffer.writeBuffer(&compressedSlice)
            compressedSlice.discardReadBytes()
            buffer.discardReadBytes()
        }
        var emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
//        var compressedEmptyBuffer = ByteBufferAllocator().buffer(capacity: 16000)
        try emptyBuffer.compressStream(to: &compressedBuffer, with: compressor, flush: .finish)
//        compressedBuffer.writeBuffer(&compressedEmptyBuffer)
        try compressor.finishStream()
        return compressedBuffer
    }

    func streamBlockCompress(_ algorithm: CompressionAlgorithm, buffer: inout ByteBuffer, blockSize: Int = 1024) throws -> [ByteBuffer] {
        let compressor = algorithm.compressor
        try compressor.startStream()
        var compressedBuffers: [ByteBuffer] = []
        let minBlockSize = blockSize / 2
        var blockSize = blockSize

        while buffer.readableBytes > 0 {
            blockSize += Int.random(in: (-blockSize / 2)..<(blockSize / 2))
            blockSize = max(blockSize, minBlockSize)
            let size = min(blockSize, buffer.readableBytes)
            var slice = buffer.readSlice(length: size)!
            var compressedSlice = try slice.compressStream(with: compressor, flush: .sync)
            compressedBuffers.append(compressedSlice)
            compressedSlice.discardReadBytes()
            buffer.discardReadBytes()
        }
        var emptyBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let compressedEmptyBlock = try emptyBuffer.compressStream(with: compressor, flush: .finish)
        compressedBuffers.append(compressedEmptyBlock)
        try compressor.finishStream()

        return compressedBuffers
    }

    func streamDecompress(_ algorithm: CompressionAlgorithm, from: inout ByteBuffer, to: inout ByteBuffer, blockSize: Int = 1024) throws {
        // decompress
        let decompressor = algorithm.decompressor
        try decompressor.startStream()
        while from.readableBytes > 0 {
            let size = min(blockSize, from.readableBytes)
            var slice = from.readSlice(length: size)!
            var writeOutBuffer = ByteBufferAllocator().buffer(capacity: to.writableBytes)
            try slice.decompressStream(to: &writeOutBuffer, with: decompressor)
            to.writeBuffer(&writeOutBuffer)
            writeOutBuffer.discardReadBytes()
            from.discardReadBytes()
        }
        try decompressor.finishStream()
    }

    func streamBlockDecompress(_ algorithm: CompressionAlgorithm, from: [ByteBuffer], to: inout ByteBuffer) throws {
        let decompressor = algorithm.decompressor
        try decompressor.startStream()
        for var buffer in from {
            var writeOutBuffer = ByteBufferAllocator().buffer(capacity: to.writableBytes)
            try buffer.decompressStream(to: &writeOutBuffer, with: decompressor)
            to.writeBuffer(&writeOutBuffer)
            writeOutBuffer.discardReadBytes()
            buffer.discardReadBytes()
        }
        try decompressor.finishStream()
    }

    func testStreamCompressDecompress(_ algorithm: CompressionAlgorithm, bufferSize: Int = 16384, blockSize: Int = 1024) throws {
        let byteBufferAllocator = ByteBufferAllocator()
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 50)

        var bufferToCompress = buffer
        var compressedBuffer = try streamCompress(algorithm, buffer: &bufferToCompress, blockSize: blockSize)

        var uncompressedBuffer = byteBufferAllocator.buffer(capacity: bufferSize + 1)
        try self.streamDecompress(algorithm, from: &compressedBuffer, to: &uncompressedBuffer, blockSize: 1024)

        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    /// testBlockStreamCompressDecompress is different from testStreamCompressDecompress as it decompresses the
    /// slice that were compressed while testStreamCompressDecompress decompresses on a arbitrary block size
    func testBlockStreamCompressDecompress(_ algorithm: CompressionAlgorithm, bufferSize: Int = 16396, blockSize: Int = 1024) throws {
        let byteBufferAllocator = ByteBufferAllocator()
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 50)

        // compress
        var bufferToCompress = buffer
        let compressedBuffers = try streamBlockCompress(algorithm, buffer: &bufferToCompress, blockSize: blockSize)

        // decompress
        var uncompressedBuffer = byteBufferAllocator.buffer(capacity: bufferSize + 1)
        try self.streamBlockDecompress(algorithm, from: compressedBuffers, to: &uncompressedBuffer)

        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func testReset(_ algorithm: CompressionAlgorithm) throws {
        let bufferSize = 12000
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 50)
        var bufferToCompress = buffer

        let compressor = algorithm.compressor
        let decompressor = algorithm.decompressor
        try compressor.startStream()
        var compressedBuffer = try bufferToCompress.compressStream(with: compressor, flush: .finish)
        try compressor.resetStream()

        try decompressor.startStream()
        var uncompressedBuffer = try compressedBuffer.decompressStream(with: decompressor)
        try decompressor.resetStream()

        XCTAssertEqual(buffer, uncompressedBuffer)

        compressedBuffer = try uncompressedBuffer.compressStream(with: compressor, flush: .finish)
        try compressor.finishStream()

        uncompressedBuffer = try compressedBuffer.decompressStream(with: decompressor)
        try decompressor.finishStream()

        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func streamCompressWindow(_ algorithm: CompressionAlgorithm, inputBufferSize: Int, streamBufferSize: Int, windowSize: Int) throws {
        // compress
        let buffer = self.createRandomBuffer(size: inputBufferSize, randomness: 40)
        let window = ByteBufferAllocator().buffer(capacity: windowSize)
        var bufferToCompress = buffer

        let compressor = algorithm.compressor
        compressor.window = window
        try compressor.startStream()
        var compressedBuffer = ByteBufferAllocator().buffer(capacity: 0)

        while bufferToCompress.readableBytes > 0 {
            let size = min(bufferToCompress.readableBytes, streamBufferSize)
            let flush: CompressNIOFlush = bufferToCompress.readableBytes - size == 0 ? .finish : .no
            var slice = bufferToCompress.readSlice(length: size)!
            try slice.compressStream(with: compressor, flush: flush) { window in
                var window = window
                compressedBuffer.writeBuffer(&window)
            }
            bufferToCompress.discardReadBytes()
        }
        try compressor.finishStream()

        let uncompressedBuffer = try compressedBuffer.decompress(with: algorithm)

        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func streamDecompressWindow(_ algorithm: CompressionAlgorithm, inputBufferSize: Int, streamBufferSize: Int, windowSize: Int) throws {
        // compress
        let buffer = self.createRandomBuffer(size: inputBufferSize, randomness: 25)
        let window = ByteBufferAllocator().buffer(capacity: windowSize)
        var bufferToCompress = buffer

        var compressedBuffer = try bufferToCompress.compress(with: algorithm)

        var uncompressedBuffer = ByteBufferAllocator().buffer(capacity: 0)
        let decompressor = algorithm.decompressor
        decompressor.window = window
        try decompressor.startStream()

        while compressedBuffer.readableBytes > 0 {
            let size = min(compressedBuffer.readableBytes, streamBufferSize)
            var slice = compressedBuffer.readSlice(length: size)!
            try slice.decompressStream(with: decompressor) { window in
                var window = window
                uncompressedBuffer.writeBuffer(&window)
            }
            compressedBuffer.discardReadBytes()
        }

        try decompressor.finishStream()
        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func testCompressionAlgorithm(_ algorithm: CompressionAlgorithm) throws {
        let buffer = self.createRandomBuffer(size: 10240, randomness: 20)
        var buffer1 = buffer
        let compressor = algorithm.compressor
        try compressor.startStream()
        var compressedBuffer = try buffer1.compressStream(with: compressor, flush: .finish)
        try compressor.finishStream()

        let decompressor = algorithm.decompressor
        try decompressor.startStream()
        let buffer2 = try compressedBuffer.decompressStream(with: decompressor)
        try decompressor.finishStream()

        XCTAssertEqual(buffer, buffer2)
    }

    func testGZipCompressDecompress() throws {
        try self.testCompressDecompress(.gzip())
    }

    func testZlibCompressDecompress() throws {
        try self.testCompressDecompress(.zlib())
    }

    func testRawDeflateCompressDecompress() throws {
        try self.testCompressDecompress(.deflate())
    }

    func testGZipStreamCompressDecompress() throws {
        try self.testStreamCompressDecompress(.gzip())
    }

    func testZlibStreamCompressDecompress() throws {
        try self.testBlockStreamCompressDecompress(.zlib())
    }

    func testRawDeflateStreamCompressDecompress() throws {
        try self.testBlockStreamCompressDecompress(.deflate())
    }

    func testGZipBlockStreamCompressDecompress() throws {
        try self.testBlockStreamCompressDecompress(.gzip())
    }

    func testZlibBlockStreamCompressDecompress() throws {
        try self.testStreamCompressDecompress(.zlib())
    }

    func testRawDeflateBlockStreamCompressDecompress() throws {
        try self.testStreamCompressDecompress(.deflate())
    }

    func testCompressWithWindow() throws {
        try self.streamCompressWindow(.deflate(), inputBufferSize: 240_000, streamBufferSize: 110_000, windowSize: 75000)
    }

    func testDecompressWithWindow() throws {
        try self.streamDecompressWindow(.gzip(), inputBufferSize: 256_000, streamBufferSize: 75000, windowSize: 32000)
    }

    func testWindowSize() throws {
        try self.testCompressionAlgorithm(.gzip(configuration: .init(windowSize: 9)))
        try self.testCompressionAlgorithm(.deflate(configuration: .init(windowSize: 12)))
    }

    func testCompressionLevel() throws {
        try self.testCompressionAlgorithm(.gzip(configuration: .init(compressionLevel: 4)))
        try self.testCompressionAlgorithm(.deflate(configuration: .init(compressionLevel: 9)))
    }

    func testMemoryLevel() throws {
        try self.testCompressionAlgorithm(.gzip(configuration: .init(memoryLevel: 2)))
        try self.testCompressionAlgorithm(.deflate(configuration: .init(memoryLevel: 9)))
    }

    func testDecompressWithInputBufferError() throws {
        var buffer1 = ByteBuffer(bytes: [0xAA, 0xE6, 0x52, 0x50, 0x50, 0x50, 0x72, 0x2C, 0x2D, 0xC9, 0x4F, 0x4A, 0xCC, 0xC8, 0x0B, 0xA8, 0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        var buffer2 = ByteBuffer(bytes: [0x2A, 0xC9, 0xC8, 0xCF, 0xD3, 0x37, 0xD0, 0x33, 0xD3, 0x33, 0x50, 0xB2, 0x52, 0xA8, 0xE6, 0x52, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        var buffer3 = ByteBuffer(bytes: [0x02, 0x03, 0x25, 0x43, 0x3D, 0x20, 0x04, 0x0B, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        var buffer4 = ByteBuffer(bytes: [0x52, 0x80, 0x01, 0xA5, 0xA4, 0xD4, 0x8C, 0xC4, 0xB2, 0x4C, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        var buffer5 = ByteBuffer(bytes: [0xCA, 0x2F, 0x02, 0x0A, 0x2B, 0xF9, 0x7B, 0x2B, 0xE9, 0x40, 0xA4, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        var buffer6 = ByteBuffer(bytes: [0x42, 0x91, 0x72, 0xCE, 0xC9, 0x07, 0x00, 0x00, 0x00, 0xFF, 0xFF])

        let decompressor = CompressionAlgorithm.deflate().decompressor
        try decompressor.startStream()
        _ = try buffer1.decompressStream(with: decompressor, maxSize: 65536)
        _ = try buffer2.decompressStream(with: decompressor, maxSize: 65536)
        _ = try buffer3.decompressStream(with: decompressor, maxSize: 65536)
        _ = try buffer4.decompressStream(with: decompressor, maxSize: 65536)
        _ = try buffer5.decompressStream(with: decompressor, maxSize: 65536)
        _ = try buffer6.decompressStream(with: decompressor, maxSize: 65536)
    }

    func testTwoStreamsInParallel() throws {
        let buffer = self.createRandomBuffer(size: 1024)
        var bufferToCompress = buffer
        let compressor = CompressionAlgorithm.gzip().compressor
        try compressor.startStream()
        var outputBuffer = ByteBufferAllocator().buffer(capacity: compressor.maxSize(from: bufferToCompress))
        let buffer2 = self.createRandomBuffer(size: 1024)
        var bufferToCompress2 = buffer2
        let compressor2 = CompressionAlgorithm.gzip().compressor
        try compressor2.startStream()
        var outputBuffer2 = ByteBufferAllocator().buffer(capacity: compressor2.maxSize(from: bufferToCompress2))
        try bufferToCompress.compressStream(to: &outputBuffer, with: compressor, flush: .finish)
        try bufferToCompress2.compressStream(to: &outputBuffer2, with: compressor2, flush: .finish)
        try compressor.finishStream()
        try compressor2.finishStream()
        var uncompressedBuffer = ByteBufferAllocator().buffer(capacity: 1024)
        try outputBuffer.decompress(to: &uncompressedBuffer, with: .gzip())
        XCTAssertEqual(buffer, uncompressedBuffer)
        var uncompressedBuffer2 = ByteBufferAllocator().buffer(capacity: 1024)
        try outputBuffer2.decompress(to: &uncompressedBuffer2, with: .gzip())
        XCTAssertEqual(buffer2, uncompressedBuffer2)
    }

    func testDecompressWithWrongAlgorithm() {
        var buffer = self.createRandomBuffer(size: 1024)
        do {
            var compressedBuffer = try buffer.compress(with: .gzip())
            var outputBuffer = ByteBufferAllocator().buffer(capacity: 1024)
            try compressedBuffer.decompress(to: &outputBuffer, with: .deflate())
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.corruptData {
        } catch {
            XCTFail()
        }
    }

    func testCompressWithOverflowError() {
        var buffer = self.createRandomBuffer(size: 1024)
        var outputBuffer = ByteBufferAllocator().buffer(capacity: 16)
        do {
            try buffer.compress(to: &outputBuffer, with: .gzip())
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.bufferOverflow {
        } catch {
            XCTFail()
        }
    }

    func testStreamCompressWithOverflowError() {
        var buffer = self.createRandomBuffer(size: 1024)
        var outputBuffer = ByteBufferAllocator().buffer(capacity: 16)
        do {
            let compressor = CompressionAlgorithm.gzip().compressor
            try compressor.startStream()
            try buffer.compressStream(to: &outputBuffer, with: compressor, flush: .finish)
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.bufferOverflow {
        } catch {
            XCTFail()
        }
    }

    func testRetryCompressAfterOverflowError() throws {
        let buffer = self.createConsistentRandomBuffer(444, 10659, size: 5041, randomness: 34)
        var bufferToCompress = buffer
        let compressor = CompressionAlgorithm.deflate().compressor
        try compressor.startStream()
        var compressedBuffer = ByteBufferAllocator().buffer(capacity: 2048)
        do {
            try bufferToCompress.compressStream(to: &compressedBuffer, with: compressor, flush: .finish)
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.bufferOverflow {
            var compressedBuffer2 = ByteBufferAllocator().buffer(capacity: 2048)
            try bufferToCompress.compressStream(to: &compressedBuffer2, with: compressor, flush: .finish)
            try compressor.finishStream()
            compressedBuffer.writeBuffer(&compressedBuffer2)
            var outputBuffer = ByteBufferAllocator().buffer(capacity: 5041)
            try compressedBuffer.decompress(to: &outputBuffer, with: .deflate())
            XCTAssertEqual(outputBuffer, buffer)
        }
    }

    func testCompressFillBuffer() throws {
        // create buffer that compresses to exactly 4096 bytes
        let buffer = self.createConsistentRandomBuffer(444, 10659, size: 5041, randomness: 34)
        var bufferToCompress = buffer
        let compressor = CompressionAlgorithm.deflate().compressor
        try compressor.startStream()
        var compressedBuffer = ByteBufferAllocator().buffer(capacity: 4096)
        try bufferToCompress.compressStream(to: &compressedBuffer, with: compressor, flush: .finish)
    }

    func testDecompressWithOverflowError() {
        var buffer = self.createRandomBuffer(size: 1024)
        do {
            var compressedBuffer = try buffer.compress(with: .gzip())
            var outputBuffer = ByteBufferAllocator().buffer(capacity: 512)
            try compressedBuffer.decompress(to: &outputBuffer, with: .gzip())
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.bufferOverflow {
        } catch {
            XCTFail()
        }
    }

    func testRetryDecompressAfterOverflowError() throws {
        let buffer = self.createRandomBuffer(size: 1024)
        var bufferToCompress = buffer
        var compressedBuffer = try bufferToCompress.compress(with: .gzip())
        let decompressor = CompressionAlgorithm.gzip().decompressor
        try decompressor.startStream()
        var outputBuffer = ByteBufferAllocator().buffer(capacity: 512)
        do {
            try compressedBuffer.decompressStream(to: &outputBuffer, with: decompressor)
            XCTFail("Shouldn't get here")
        } catch let error as CompressNIOError where error == CompressNIOError.bufferOverflow {
            var outputBuffer2 = ByteBufferAllocator().buffer(capacity: 1024)
            try compressedBuffer.decompressStream(to: &outputBuffer2, with: decompressor)
            outputBuffer.writeBuffer(&outputBuffer2)
            XCTAssertEqual(outputBuffer, buffer)
        }
        try decompressor.finishStream()
    }

    func testAllocatingDecompress() throws {
        let bufferSize = 16000
        // create a buffer that will compress well
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 10)
        var bufferToCompress = buffer
        var compressedBuffer = try bufferToCompress.compress(with: .gzip())
        let uncompressedBuffer = try compressedBuffer.decompress(with: .gzip())
        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func testRandomAllocatingDecompress() throws {
        let bufferSize = 16000
        // create a buffer that will compress well
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 100)
        var bufferToCompress = buffer
        var compressedBuffer = try bufferToCompress.compress(with: .gzip())
        let uncompressedBuffer = try compressedBuffer.decompress(with: .gzip())
        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func testAllocatingStreamCompressDecompress() throws {
        let algorithm: CompressionAlgorithm = .gzip()
        let bufferSize = 16000
        let blockSize = 1024
        let buffer = self.createRandomBuffer(size: bufferSize, randomness: 25)

        // compress
        var bufferToCompress = buffer
        let compressor = algorithm.compressor
        try compressor.startStream()
        var compressedBuffer = ByteBufferAllocator().buffer(capacity: compressor.maxSize(from: bufferToCompress))

        while bufferToCompress.readableBytes > 0 {
            let size = min(blockSize, bufferToCompress.readableBytes)
            let flush: CompressNIOFlush = bufferToCompress.readableBytes - size == 0 ? .finish : .sync
            var slice = bufferToCompress.readSlice(length: size)!
            var compressedSlice = try slice.compressStream(with: compressor, flush: flush)
            compressedBuffer.writeBuffer(&compressedSlice)
            bufferToCompress.discardReadBytes()
        }
        try compressor.finishStream()

        // decompress
        var uncompressedBuffer = ByteBufferAllocator().buffer(capacity: bufferSize)
        let decompressor = algorithm.decompressor
        try decompressor.startStream()
        while compressedBuffer.readableBytes > 0 {
            let size = min(1024, compressedBuffer.readableBytes)
            var slice = compressedBuffer.readSlice(length: size)!
            var uncompressedBuffer2 = try slice.decompressStream(with: decompressor)
            uncompressedBuffer.writeBuffer(&uncompressedBuffer2)
            compressedBuffer.discardReadBytes()
        }
        try decompressor.finishStream()

        XCTAssertEqual(buffer, uncompressedBuffer)
    }

    func testGZipReset() throws {
        try self.testReset(.gzip())
    }

    func testDecompressMaxSize() throws {
        var uncompressedBuffer = self.createRandomBuffer(size: 1025)
        let compressedBuffer = try uncompressedBuffer.compress(with: .deflate())

        var copy = compressedBuffer
        XCTAssertNoThrow(_ = try copy.decompress(with: .deflate(), maxSize: 1100))

        var copy2 = compressedBuffer
        XCTAssertThrowsError(_ = try copy2.decompress(with: .deflate(), maxSize: 1000)) { error in
            XCTAssertEqual(error as? CompressNIOError, .bufferOverflow)
        }
    }
}
