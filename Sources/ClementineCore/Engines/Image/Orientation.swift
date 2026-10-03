import Foundation

/// EXIF orientations (1…8) as 2×2 integer matrices acting on y-down image
/// coordinates, so rotations and flips can be composed losslessly.
public enum ExifOrientation {
    private static let matrices: [Int: [Int]] = [
        1: [1, 0, 0, 1],
        2: [-1, 0, 0, 1],   // mirror horizontally
        3: [-1, 0, 0, -1],  // rotate 180°
        4: [1, 0, 0, -1],   // mirror vertically
        5: [0, 1, 1, 0],    // transpose
        6: [0, -1, 1, 0],   // rotate 90° clockwise
        7: [0, -1, -1, 0],  // transverse
        8: [0, 1, -1, 0],   // rotate 90° counter-clockwise
    ]

    /// The orientation after applying `turn` and flips to an image that
    /// currently displays with `current`.
    public static func compose(_ current: Int, turn: RotateOptions.Turn, flipHorizontal: Bool, flipVertical: Bool) -> Int {
        var m = matrices[current] ?? matrices[1]!
        if flipHorizontal { m = multiply(matrices[2]!, m) }
        if flipVertical { m = multiply(matrices[4]!, m) }
        switch turn {
        case .none: break
        case .right: m = multiply(matrices[6]!, m)
        case .half: m = multiply(matrices[3]!, m)
        case .left: m = multiply(matrices[8]!, m)
        }
        return matrices.first { $0.value == m }?.key ?? current
    }

    /// Row-major 2×2 product a·b.
    static func multiply(_ a: [Int], _ b: [Int]) -> [Int] {
        [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
         a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]
    }

    /// Whether the orientation swaps width and height.
    public static func swapsAxes(_ orientation: Int) -> Bool { (5...8).contains(orientation) }
}
