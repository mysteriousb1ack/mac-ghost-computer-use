import Foundation
import CoreGraphics

struct Crop: Decodable {
    let x, y, width, height: Double

    static func parse(_ raw: String?) throws -> Crop {
        guard let raw else { return Crop(x: 0, y: 0, width: 1, height: 1) }
        guard let crop = try? JSONDecoder().decode(Crop.self, from: Data(raw.utf8)),
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x < 1, crop.y < 1, crop.x + crop.width <= 1, crop.y + crop.height <= 1
        else { throw Failure("INVALID_ARGUMENT", "Use a nonempty normalized crop inside the window.") }
        return crop
    }
}

// Snap outwards to actual source pixels. Use the same rectangle for the image
// and for window-local coordinates (independent of Retina scale or screen origin).
struct CaptureGeometry {
    let pixels: CGRect
    let sx, sy: CGFloat
    init(crop: Crop, width: Int, height: Int, window: CGSize) {
        let w = CGFloat(width), h = CGFloat(height)
        // Decimal crop edges such as 0.1 + 0.2 can land one ULP above an
        // integer. Snap only numerical noise before rounding outward.
        func edge(_ position: CGFloat) -> CGFloat {
            let nearest = position.rounded()
            return abs(nearest - position) <= position.ulp * 2 ? nearest : position
        }
        let left = min(w - 1, floor(edge(crop.x * w))), top = min(h - 1, floor(edge(crop.y * h)))
        let right = min(w, max(left + 1, ceil(edge((crop.x + crop.width) * w))))
        let bottom = min(h, max(top + 1, ceil(edge((crop.y + crop.height) * h))))
        pixels = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        sx = window.width / w
        sy = window.height / h
    }
    func clip(_ image: CGImage) throws -> CGImage {
        guard let clipped = image.cropping(to: pixels) else { throw Failure("IMAGE_ERROR", "Cannot crop window image.") }
        return clipped
    }

    func metadata(grid: (Int, Int)?) -> Object {
        var cells = [String: [String: CGFloat]]()
        if let (columns, rows) = grid {
            for row in 0..<rows {
                for col in 0..<columns {
                    let x = pixels.minX + (CGFloat(col) + 0.5) * pixels.width / CGFloat(columns)
                    let y = pixels.minY + (CGFloat(row) + 0.5) * pixels.height / CGFloat(rows)
                    cells["\(UnicodeScalar(65 + col)!)\(row + 1)"] = ["x": x * sx, "y": y * sy]
                }
            }
        }
        return ["cropPixels": rectJSON(pixels), "pointOrigin": ["x": pixels.minX * sx, "y": pixels.minY * sy],
                "pointsPerPixelX": sx, "pointsPerPixelY": sy, "cellToPoint": cells]
    }
}
