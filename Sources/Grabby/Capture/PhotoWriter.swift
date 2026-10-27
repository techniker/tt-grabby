import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum PhotoFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg, heic
    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

enum PhotoWriter {
    private static let context = CIContext()

    /// Saves a frame with square pixels (768x576 for PAL, 640x480 for NTSC).
    static func save(_ frame: VideoFrame, format: PhotoFormat, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = 1
        scale.aspectRatio = Float(frame.norm.pixelAspect.h) / Float(frame.norm.pixelAspect.v)
        guard let output = scale.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent.integral,
                                                  format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { throw PhotoError.renderFailed }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw PhotoError.writeFailed }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoError.writeFailed }
    }
}

enum PhotoError: LocalizedError {
    case noFrame, renderFailed, writeFailed
    var errorDescription: String? {
        switch self {
        case .noFrame: "There is no video picture to save yet."
        case .renderFailed: "The picture could not be converted."
        case .writeFailed: "The picture could not be saved."
        }
    }
}
