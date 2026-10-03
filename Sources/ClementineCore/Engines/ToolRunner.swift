#if canImport(ImageIO)
import Foundation

/// Runs ⇧⌥-wheel tools.
enum ToolRunner {
    static func run(_ tool: Tool, job: Job, engines: Engines) async throws -> JobResult {
        let request = job.request
        guard let first = request.inputs.first else { throw JobFailure("There's nothing to work on.") }
        switch tool {
        case .removeMetadata:
            guard let format = first.format else { throw JobFailure("This file type isn't supported.") }
            return try await engines.withOutput(for: first, suffix: tool.outputSuffix, extension: format.fileExtension,
                                                request: request) { url in
                try await ImageTools.stripMetadata(first, to: url, settings: engines.settings)
            }
        case .readQR:
            let decoded = try ImageCodec.decode(first.url, format: first.format)
            job.report(0.5)
            let codes = try ImageTools.readCodes(in: decoded.image)
            guard !codes.isEmpty else { throw JobFailure("No QR code or barcode found in this image.") }
            return JobResult(text: codes.joined(separator: "\n"))
        default:
            throw JobFailure("\(tool.displayName) isn't available in this version yet.")
        }
    }
}
#endif
