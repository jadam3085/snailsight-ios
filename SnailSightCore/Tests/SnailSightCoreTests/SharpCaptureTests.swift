import XCTest
import simd
@testable import SnailSightCore

/// 9.4 sharp captures: blur prediction, sharpness, keyframe window / picker, slow-down hint, camera policy, object
/// auto-fit on a table, keyframes.csv quality columns.
final class SharpCaptureTests: XCTestCase {
    func testPredictedBlur() {
        // 1 rad/s at 1/60 s with f = 1370 px ≈ 22.8 px; at 1/250 s ≈ 5.5 px
        XCTAssertEqual(KeyframeQuality.predictedBlurPx(angularSpeedRadS: 1, linearSpeedMS: 0, depthM: 1,
                                                       exposureS: 1.0 / 60, focalPx: 1370), 22.83, accuracy: 0.01)
        XCTAssertEqual(KeyframeQuality.predictedBlurPx(angularSpeedRadS: 1, linearSpeedMS: 0, depthM: 1,
                                                       exposureS: CameraPolicy.sharpMaxExposureS, focalPx: 1370), 5.48, accuracy: 0.01)
        // 0.5 m/s past something 0.5 m away at 1/250 s: 0.004 × 1370 × 1 = 5.48 px
        XCTAssertEqual(KeyframeQuality.predictedBlurPx(angularSpeedRadS: 0, linearSpeedMS: 0.5, depthM: 0.5,
                                                       exposureS: 0.004, focalPx: 1370), 5.48, accuracy: 0.01)
    }

    private func checker(_ w: Int, _ h: Int, blur: Int) -> [UInt8] {
        var img = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { img[y * w + x] = ((x / 8 + y / 8) % 2 == 0) ? 230 : 20 } }
        guard blur > 0 else { return img }
        var out = img                                         // horizontal box blur = motion blur
        for y in 0..<h { for x in 0..<w {
            var s = 0, n = 0
            for d in -blur...blur where x + d >= 0 && x + d < w { s += Int(img[y * w + x + d]); n += 1 }
            out[y * w + x] = UInt8(s / n)
        } }
        return out
    }

    func testSharpnessDropsWithMotionBlur() {
        let sharp = KeyframeQuality.laplacianVariance(checker(320, 240, blur: 0), width: 320, height: 240)
        let soft = KeyframeQuality.laplacianVariance(checker(320, 240, blur: 6), width: 320, height: 240)
        let softer = KeyframeQuality.laplacianVariance(checker(320, 240, blur: 16), width: 320, height: 240)
        XCTAssertGreaterThan(sharp, soft * 1.5)
        XCTAssertGreaterThan(soft, softer)
        XCTAssertEqual(KeyframeQuality.laplacianVariance([UInt8](repeating: 128, count: 64 * 64), width: 64, height: 64), 0)
    }

    func testKeyframeWindowAndPicker() {
        XCTAssertEqual(KeyframeWindow.length(scale: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(KeyframeWindow.length(scale: ObjectProfile.keyframeScale), 0.36, accuracy: 1e-9)
        var w = KeyframeWindow(length: 0.6)
        XCTAssertNil(w.candidate(at: 0, blurPx: 0))
        w.open(at: 10)
        XCTAssertEqual(w.candidate(at: 10.0, blurPx: 5), 1)
        XCTAssertEqual(w.candidate(at: 10.5, blurPx: 4), 1)
        XCTAssertEqual(w.candidate(at: 10.7, blurPx: 3), 1)          // past its length but nothing sharp yet: extended
        XCTAssertEqual(w.candidate(at: 10.9, blurPx: 1), 1)
        XCTAssertNil(w.candidate(at: 11.0, blurPx: 1))                // sharp one seen + past length: closed
        XCTAssertFalse(w.isOpen)
        w.open(at: 20)
        XCTAssertEqual(w.candidate(at: 21.0, blurPx: 9), 2)
        XCTAssertNil(w.candidate(at: 21.3, blurPx: 9))                // 2× length: closed regardless

        var p = KeyframePicker<Int?>()
        let scores: [Int: Double] = [1: 5, 2: 9, 3: 2, 7: 1, 8: 3]
        XCTAssertNil(p.offer(window: 1, payload: 1, score: { scores[1]! }))
        XCTAssertNil(p.offer(window: 1, payload: 2, score: { scores[2]! }))
        XCTAssertNil(p.offer(window: 1, payload: 3, score: { scores[3]! }))
        var evaluated = false
        let pick = p.offer(window: nil, payload: nil, score: { evaluated = true; return 0 })
        XCTAssertFalse(evaluated)                                     // non-candidates are never scored
        XCTAssertEqual(pick?.payload, 2)
        XCTAssertEqual(pick?.candidates, 3)
        XCTAssertNil(p.offer(window: 2, payload: 7, score: { scores[7]! }))
        let p2 = p.offer(window: 3, payload: 8, score: { scores[8]! })   // window 2 → 3 directly
        XCTAssertEqual(p2?.payload, 7)
        XCTAssertEqual(p.flush()?.payload, 8)
        XCTAssertNil(p.flush())
    }

    func testCameraPolicy() {
        XCTAssertEqual(CameraPolicy.plan(mode: .auto, recording: true, objectScan: true),
                       CameraPlan(maxExposureS: nil, lockWhiteBalance: false, lockExposure: false))
        XCTAssertEqual(CameraPolicy.plan(mode: .sharp, recording: false, objectScan: false),
                       CameraPlan(maxExposureS: 0.004, lockWhiteBalance: false, lockExposure: false))
        XCTAssertEqual(CameraPolicy.plan(mode: .sharp, recording: true, objectScan: false),
                       CameraPlan(maxExposureS: 0.004, lockWhiteBalance: true, lockExposure: false))
        XCTAssertEqual(CameraPolicy.plan(mode: .sharp, recording: true, objectScan: true),
                       CameraPlan(maxExposureS: 0.004, lockWhiteBalance: true, lockExposure: true))
        XCTAssertEqual(CameraPolicy.clampExposure(0.004, minS: 0.000_014, maxS: 1.0 / 60), 0.004)
        XCTAssertEqual(CameraPolicy.clampExposure(0.004, minS: 0.000_014, maxS: 0.002), 0.002)
        XCTAssertEqual(CameraMode(rawValue: "sharp"), .sharp)
    }

    func testKeyframeLineWithQuality() {
        XCTAssertEqual(CaptureFormat.keyframeLine(frame: 7, timestamp: 1.5, width: 1920, height: 1440, fx: 1400.25, fy: 1400,
                                                  cx: 960, cy: 720.5, sharpness: 812.345, blurPx: 1.25, exposureS: 0.004,
                                                  iso: 640, candidates: 5),
                       "7, 1.500000, 1920, 1440, 1400.2500, 1400.0000, 960.0000, 720.5000, 812.35, 1.25, 0.004000, 640, 5\n")
        XCTAssertEqual(CaptureFormat.keyframesHeader.split(separator: ",").count, 13)
    }

    /// Dense samples of a table top (0.9 m square at y = 0.75), a 0.22 × 0.07 × 0.20 m box on it (yawed 20°) and a cup
    /// 10 cm away; the floor (y = 0) around the table.
    private func tableScene() -> (pts: [SIMD3<Float>], hitTop: SIMD3<Float>) {
        var pts: [SIMD3<Float>] = []
        let s: Float = 0.015
        for x in stride(from: Float(-1.2), through: 1.2, by: 0.04) { for z in stride(from: Float(-1.2), through: 1.2, by: 0.04)
            where abs(x) > 0.45 || abs(z) > 0.45 { pts.append(SIMD3(x, 0, z)) } }
        for x in stride(from: Float(-0.45), through: 0.45, by: s) { for z in stride(from: Float(-0.45), through: 0.45, by: s) {
            pts.append(SIMD3(x, 0.75, z)) } }
        let yaw: Float = 20 * .pi / 180
        let xa = SIMD3<Float>(cos(yaw), 0, -sin(yaw)), za = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        let c = SIMD3<Float>(0.05, 0.75, -0.05)
        for u in stride(from: Float(-0.11), through: 0.11, by: 0.01) { for v in stride(from: Float(-0.10), through: 0.10, by: 0.01) {
            pts.append(c + xa * u + za * v + SIMD3(0, 0.07, 0)) } }                        // top
        for h in stride(from: Float(0.0), through: 0.07, by: 0.01) {
            for u in stride(from: Float(-0.11), through: 0.11, by: 0.01) {
                pts.append(c + xa * u + za * 0.10 + SIMD3(0, h, 0)); pts.append(c + xa * u - za * 0.10 + SIMD3(0, h, 0)) }
            for v in stride(from: Float(-0.10), through: 0.10, by: 0.01) {
                pts.append(c + xa * 0.11 + za * v + SIMD3(0, h, 0)); pts.append(c - xa * 0.11 + za * v + SIMD3(0, h, 0)) }
        }
        let cup = SIMD3<Float>(0.32, 0.75, 0.25)                                            // ~12 cm from the box
        for h in stride(from: Float(0.0), through: 0.12, by: 0.01) {
            for a in stride(from: Float(0), to: 2 * .pi, by: 0.3) { pts.append(cup + SIMD3(0.035 * cos(a), h, 0.035 * sin(a))) } }
        return (pts, c + SIMD3(0, 0.07, 0))
    }

    func testAutoFitOnTable() throws {
        let (pts, hit) = tableScene()
        let f = try XCTUnwrap(ObjectAutoFit.fit(points: pts, hit: hit, camera: SIMD3(0.05, 1.2, 0.6)))
        XCTAssertEqual(f.supportY, 0.75, accuracy: 0.011)              // the table, not the floor
        XCTAssertEqual(f.box.floorY, f.supportY)
        XCTAssertEqual(f.box.size.y, 0.07 + ObjectAutoFit.margin, accuracy: 0.015)
        let fp = [f.box.size.x, f.box.size.z].sorted()
        XCTAssertEqual(fp[0], 0.20 + 2 * ObjectAutoFit.margin, accuracy: 0.04)
        XCTAssertEqual(fp[1], 0.22 + 2 * ObjectAutoFit.margin, accuracy: 0.04)
        XCTAssertFalse(f.box.contains(SIMD3(0.32, 0.80, 0.25)))      // the cup stays out
        XCTAssertTrue(f.box.contains(SIMD3(0.05, 0.78, -0.05)))
        XCTAssertGreaterThanOrEqual(f.sides, 4)
        XCTAssertLessThan(f.box.size.x, ObjectBox.defaultSize.x)      // not the old 1.0 × 0.8 × 0.8 default
    }

    func testAutoFitNeedsMesh() {
        XCTAssertNil(ObjectAutoFit.fit(points: [SIMD3(0, 0, 0)], hit: SIMD3(0, 0.1, 0), camera: SIMD3(0, 1, 1)))
    }

    func testObjectScanDefaults() {
        // owner 2026-10-13: no "RoboSnailBob" default, robot tag off, name required (ObjectNameRule)
        XCTAssertFalse(ObjectNameRule.isValid(""))
        XCTAssertFalse(ObjectNameRule.isValid("   "))
        XCTAssertTrue(ObjectNameRule.isValid("NAD9 mini PC"))
        XCTAssertEqual(ObjectNameRule.clean("  NAD9 mini PC  "), "NAD9 mini PC")
        XCTAssertFalse(ObjectNameRule.defaultRobotTag)
        XCTAssertEqual(ObjectNameRule.defaultName, "")
    }
}
