import XCTest
@testable import SnailSightCore

/// 12.21 Live map view look + warm-on-open debounce.
final class LiveViewTests: XCTestCase {
    static let grey = SIMD3<Double>(128, 128, 128)
    static let portalBlue = SIMD3<Double>(0.55, 0.85, 1) * 255      // the pale blue the portal lane found hard to see

    func testShadedPaletteStaysColourfulAndDistinct() {
        // every orientation, any light: saturated (far from grey) and never black
        var floors: [SIMD3<Double>] = [], walls: [SIMD3<Double>] = []
        for i in 0..<36 {
            let a = Double(i) * .pi / 18
            let wall = LiveViewLook.shade(normal: [cos(a), sin(a), 0], photo: nil)
            walls.append(wall)
            XCTAssertGreaterThan(LiveViewLook.chroma(wall), 80)
            XCTAssertGreaterThan(wall.x + wall.y + wall.z, 120)
        }
        for n in [SIMD3<Double>(0, 0, 1), [0.3, 0, 0.95]] {
            let f = LiveViewLook.shade(normal: n / (n * n).sum().squareRoot(), photo: nil)
            floors.append(f)
            XCTAssertGreaterThan(LiveViewLook.chroma(f), 80)
        }
        let ceil = LiveViewLook.shade(normal: [0, 0, -1], photo: nil)
        XCTAssertGreaterThan(LiveViewLook.chroma(ceil), 60)
        // floors read teal (green-blue dominant), walls amber (red dominant): never confused
        for f in floors { XCTAssertGreaterThan(f.y, f.x) }
        for w in walls { XCTAssertGreaterThan(w.x, w.z * 2) }
        // shading varies with orientation (solid, shaded), so corners read
        let lums = walls.map { LiveViewLook.luminance($0) }
        XCTAssertGreaterThan(lums.max()! / lums.min()!, 1.6)
        // nothing like the pale portal blue: far in colour
        for c in walls + floors {
            let d = c - Self.portalBlue
            XCTAssertGreaterThan((d * d).sum().squareRoot(), 90)
        }
        // a photo colour (grey wall) only tints: still amber
        let tinted = LiveViewLook.shade(normal: [1, 0, 0], photo: Self.grey)
        XCTAssertGreaterThan(LiveViewLook.chroma(tinted), 60)
    }

    func testFaceColoursAndStripFromFaceColours() {
        // a floor triangle (normal +z) and a wall triangle (normal +x)
        let m = FlatMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0,   0, 0, 0, 0, 1, 0, 0, 0, 1],
                         indices: [0, 1, 2, 3, 4, 5])
        let fc = LiveViewLook.faceColours(m, rgb: nil)
        XCTAssertEqual(fc.count, 6)
        XCTAssertGreaterThan(fc[1], fc[0])                     // floor: teal
        XCTAssertGreaterThan(fc[3], fc[5])                     // wall: amber
        let ft = LiveMeshTile.faceTextured(m, faceRGB: fc)!
        XCTAssertEqual(ft.positions.count, 18)                 // unwelded: 3 vertices a face
        XCTAssertEqual(Array(ft.rgba[0..<3]), Array(fc[0..<3]))
        XCTAssertEqual(Array(ft.rgba[4..<7]), Array(fc[3..<6]))
        XCTAssertNil(LiveMeshTile.faceTextured(m, faceRGB: [1, 2]))
        // the per-vertex path is unchanged: averaging per face then the same strip
        let rgb: [UInt8] = [10, 20, 30, 10, 20, 30, 10, 20, 30, 200, 100, 0, 200, 100, 0, 200, 100, 0]
        XCTAssertEqual(LiveMeshTile.faceTextured(m, rgb: rgb), LiveMeshTile.faceTextured(m, faceRGB: LiveMeshTile.faceColours(m, rgb: rgb)))
        // photo colour of the wrong size is ignored, not a crash
        XCTAssertEqual(LiveViewLook.faceColours(m, rgb: [1, 2, 3]), fc)
    }

    func testARLookToggle() {
        XCTAssertEqual(ARLook.device.toggled, .live)
        XCTAssertEqual(ARLook.live.toggled, .device)
        XCTAssertEqual(ARLook(rawValue: "live"), .live)
        XCTAssertNil(ARLook(rawValue: ""))                     // first launch -> .device (the 12.18 look)
    }

    func testWarmDebounceOncePerMinute() {
        var w = WarmDebounce(minS: 60)
        XCTAssertTrue(w.shouldFire(now: 0))                    // launch
        XCTAssertFalse(w.shouldFire(now: 5))                   // foreground right after
        XCTAssertFalse(w.shouldFire(now: 59.9))                // Live map on
        XCTAssertTrue(w.shouldFire(now: 60))
        XCTAssertEqual(w.fired, 2)
        XCTAssertEqual(w.skipped, 2)
        w.failed()                                             // offline: the next trigger may try at once
        XCTAssertTrue(w.shouldFire(now: 61))
        XCTAssertTrue(w.shouldFire(now: 10))                   // clock went back: fire rather than stall
    }
}
