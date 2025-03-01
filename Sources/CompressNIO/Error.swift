
import NIOCore

/// Errors returned from compression/decompression routines
public struct CompressNIOError: Swift.Error, CustomStringConvertible, Equatable {
    fileprivate enum ErrorEnum: String {
        case bufferOverflow
        case inputBufferOverflow
        case corruptData
        case noMoreMemory
        case unfinished
        case internalError
        case uninitializedStream
    }

    fileprivate let error: ErrorEnum

    /// return as String
    public var description: String { return self.error.rawValue }

    /// output buffer is too small
    public static let bufferOverflow = CompressNIOError(error: .bufferOverflow)
    /// input buffer is too small
    public static let inputBufferOverflow = CompressNIOError(error: .inputBufferOverflow)
    /// input data is corrupt
    public static let corruptData = CompressNIOError(error: .corruptData)
    /// ran out of memory
    public static let noMoreMemory = CompressNIOError(error: .noMoreMemory)
    /// called `streamFinish`while there is still data to process
    public static let unfinished = CompressNIOError(error: .unfinished)
    /// called stream function while stream was unintialised
    public static let uninitializedStream = CompressNIOError(error: .uninitializedStream)
    /// error internal to system
    public static let internalError = CompressNIOError(error: .internalError)
}
