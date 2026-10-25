import Foundation

enum GIFMaker {
    /// GIF has no inter-frame compression to speak of, so size tracks pixels × frames.
    /// (GIFs themselves are made by FFmpeg, which builds an optimised palette.)
    static func estimatedBytes(info: MediaInfo, options: GIFOptions) -> Int64 {
        guard info.width > 0 else { return 0 }
        let height = Double(options.width) * Double(info.height) / Double(info.width)
        let frames = info.duration * Double(options.fps)
        return Int64(Double(options.width) * height * frames * 0.3)
    }
}
