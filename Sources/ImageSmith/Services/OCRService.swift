import AppKit
@preconcurrency import Vision

enum OCRService {
    /// Runs Vision text recognition and returns the text in reading order.
    static func recognizeText(in image: NSImage) async -> String {
        guard let cg = ImageUtilities.cgImage(from: image) else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision's origin is bottom-left; sort top-to-bottom, then left-to-right.
                let lines = observations
                    .sorted { a, b in
                        if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                            return a.boundingBox.midY > b.boundingBox.midY
                        }
                        return a.boundingBox.minX < b.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(returning: "") }
            }
        }
    }

    /// Reads any barcodes/QR codes in the image.
    static func detectBarcodes(in image: NSImage) async -> [String] {
        guard let cg = ImageUtilities.cgImage(from: image) else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, _ in
                let payloads = (request.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue } ?? []
                continuation.resume(returning: payloads)
            }
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(returning: []) }
            }
        }
    }
}
