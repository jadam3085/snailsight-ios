import XCTest
@testable import SnailSightCore

/// 12.22 `geo` per live keyframe (API §6b.13). Coordinates are SYNTHETIC (no real places in this public repo).
final class GeoPriorTests: XCTestCase {
    static let lat0 = 10.0, lon0 = 20.0

    // MARK: header encoding

    func testGeoHeaderEncodingFullAndRoundTrip() throws {
        let g = LiveGeo(lat: 10.123456789, lon: -20.5, hAccM: 4.734, altM: 12.345, vAccM: 3.2, headingDeg: 361.5,
                        headingAccDeg: 7.25, baroRelM: -0.4567, source: "phone", t: 1_700_000_000.1234)
        let h = LiveKeyframeHeader(seq: 3, streamID: "ar-0000abcd", t: 1, wall: 2, T: [Double](repeating: 0, count: 16),
                                   K: [1, 1, 0, 0], imageSize: [4, 3], geo: g)
        let data = try XCTUnwrap(LiveKeyframe.encode(h, blobs: [(name: "depth_png", data: Data([1, 2]))]))
        let (o, blobs) = try XCTUnwrap(LiveKeyframe.parse(data))
        XCTAssertEqual(blobs.count, 1)
        let geo = try XCTUnwrap(o["geo"] as? [String: Any])
        XCTAssertEqual((geo["lat"] as? NSNumber)?.doubleValue ?? 0, 10.12345679, accuracy: 1e-9)
        XCTAssertEqual((geo["lon"] as? NSNumber)?.doubleValue, -20.5)
        XCTAssertEqual((geo["h_acc_m"] as? NSNumber)?.doubleValue, 4.73)
        XCTAssertEqual((geo["alt_m"] as? NSNumber)?.doubleValue, 12.35)       // rounding to cm
        XCTAssertEqual((geo["v_acc_m"] as? NSNumber)?.doubleValue, 3.2)
        XCTAssertEqual((geo["heading_deg"] as? NSNumber)?.doubleValue ?? 0, 1.5, accuracy: 1e-9)   // wrapped to [0, 360)
        XCTAssertEqual(geo["heading_ref"] as? String, "camera")
        XCTAssertEqual((geo["heading_acc_deg"] as? NSNumber)?.doubleValue, 7.25)
        XCTAssertEqual((geo["baro_rel_m"] as? NSNumber)?.doubleValue ?? 0, -0.457, accuracy: 1e-9)
        XCTAssertEqual(geo["source"] as? String, "phone")
        XCTAssertEqual((geo["t"] as? NSNumber)?.doubleValue ?? 0, 1_700_000_000.123, accuracy: 1e-6)
    }

    func testGeoHeaderOmitsUnknownsAndNoHeaderKeyWithoutGeo() throws {
        let g = LiveGeo(lat: 1, lon: 2, hAccM: 30, headingAccDeg: 9, baroRelM: .nan)
        let o = g.json
        XCTAssertNil(o["alt_m"]); XCTAssertNil(o["v_acc_m"])
        XCTAssertNil(o["heading_deg"]); XCTAssertNil(o["heading_ref"]); XCTAssertNil(o["heading_acc_deg"])
        XCTAssertNil(o["baro_rel_m"]); XCTAssertNil(o["t"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(o))
        let h = LiveKeyframeHeader(seq: 0, streamID: "ar-00000001", t: 0, wall: 0, T: [Double](repeating: 0, count: 16),
                                   K: [1, 1, 0, 0], imageSize: [1, 1])
        XCTAssertNil(LiveKeyframe.headerObject(h, blobs: [])["geo"])        // older behaviour unchanged
    }

    func testFixGateDropsInvalidStaleAndCoarse() {
        func mk(_ acc: Double, age: Double = 1, lat: Double = 10, vAcc: Double? = 2) -> LiveGeo? {
            LiveGeoFix.make(lat: lat, lon: 20, hAccM: acc, altM: 5, vAccM: vAcc, fixTime: 100 - age, now: 100,
                            heading: (90, 6), baroRelM: 0.2)
        }
        XCTAssertNotNil(mk(5))
        XCTAssertNil(mk(-1))                       // CoreLocation: negative accuracy = invalid
        XCTAssertNil(mk(150))                      // > 100 m (the server ignores it anyway)
        XCTAssertNil(mk(5, age: 11))               // stale
        XCTAssertNil(mk(5, lat: 95))
        XCTAssertNil(LiveGeoFix.make(lat: 0, lon: 0, hAccM: 5, altM: nil, vAccM: nil, fixTime: 100, now: 100, heading: nil, baroRelM: nil))
        let noAlt = mk(5, vAcc: -1)                // negative vertical accuracy = altitude invalid
        XCTAssertNil(noAlt?.altM); XCTAssertNil(noAlt?.vAccM)
        XCTAssertEqual(mk(5)?.headingDeg, 90)
        XCTAssertEqual(mk(5)?.t, 99)
    }

    // MARK: heading

    /// A camera transform (ARKit, y up) looking along ARKit yaw `deg` (clockwise from -z towards +x), level.
    static func camT(yawDeg: Double, pitchDeg: Double = 0) -> [Double] {
        let y = yawDeg * .pi / 180, p = pitchDeg * .pi / 180
        let fwd = [sin(y) * cos(p), sin(p), -cos(y) * cos(p)]        // camera -z in the world
        let z = fwd.map { -$0 }
        let up = [0.0, 1, 0]
        var x = [up[1] * z[2] - up[2] * z[1], up[2] * z[0] - up[0] * z[2], up[0] * z[1] - up[1] * z[0]]
        let n = (x[0] * x[0] + x[1] * x[1] + x[2] * x[2]).squareRoot()
        x = n > 1e-9 ? x.map { $0 / n } : [1, 0, 0]
        let yv = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]]
        return [x[0], yv[0], z[0], 0, x[1], yv[1], z[1], 0, x[2], yv[2], z[2], 0, 0, 0, 0, 1]
    }

    func testArkitYawOfCameraAxis() {
        XCTAssertEqual(GeoHeading.arkitYawDeg(T: Self.camT(yawDeg: 0)) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(GeoHeading.arkitYawDeg(T: Self.camT(yawDeg: 90)) ?? -1, 90, accuracy: 1e-9)
        XCTAssertEqual(GeoHeading.arkitYawDeg(T: Self.camT(yawDeg: 250, pitchDeg: -40)) ?? -1, 250, accuracy: 1e-9)
        XCTAssertNil(GeoHeading.arkitYawDeg(T: Self.camT(yawDeg: 10, pitchDeg: -89)))   // looking at the floor
    }

    /// CoreMotion: whichever matrix direction maps the measured gravity to (0, 0, -1) is used.
    func testCameraAxisFromAttitudeBothConventions() throws {
        // device upright in portrait, back camera facing true SOUTH: device -z = south, so the screen (+z) faces north.
        // device axes in the north-west-up frame: x (right) = up x north = west, y (top) = up, z = north
        let xd = [0.0, 1, 0], yd = [0.0, 0, 1], zd = [1.0, 0, 0]
        // R_dev->ref has device axes as columns (not symmetric, so the two conventions differ)
        let R = [xd[0], yd[0], zd[0], xd[1], yd[1], zd[1], xd[2], yd[2], zd[2]]
        let gDev = [0.0, -1, 0]                                   // gravity along device -y (upright)
        let a = try XCTUnwrap(GeoHeading.cameraAxisNorthWestUp(rotation: R, gravityDevice: gDev))
        XCTAssertFalse(a.transposed)
        XCTAssertEqual(GeoHeading.trueHeadingDeg(northWestUp: a.axis) ?? -1, 180, accuracy: 1e-9)
        let Rt = [R[0], R[3], R[6], R[1], R[4], R[7], R[2], R[5], R[8]]
        let b = try XCTUnwrap(GeoHeading.cameraAxisNorthWestUp(rotation: Rt, gravityDevice: gDev))
        XCTAssertTrue(b.transposed)
        XCTAssertEqual(GeoHeading.trueHeadingDeg(northWestUp: b.axis) ?? -1, 180, accuracy: 1e-9)
        // facing east (x = south, z = west): 90
        let xe = [-1.0, 0, 0], ze = [0.0, 1, 0]
        let Re = [xe[0], yd[0], ze[0], xe[1], yd[1], ze[1], xe[2], yd[2], ze[2]]
        let e = try XCTUnwrap(GeoHeading.cameraAxisNorthWestUp(rotation: Re, gravityDevice: gDev))
        XCTAssertEqual(GeoHeading.trueHeadingDeg(northWestUp: e.axis) ?? -1, 90, accuracy: 1e-9)
        XCTAssertNil(GeoHeading.cameraAxisNorthWestUp(rotation: R, gravityDevice: [0, 0, 0]))
        XCTAssertNil(GeoHeading.cameraAxisNorthWestUp(rotation: R, gravityDevice: [1, 0, 0]))   // inconsistent
    }

    func testHeadingFilterCarriesCompassOnArkitYawWithHonestAccuracy() throws {
        var f = GeoHeading()
        // ARKit world is rotated: true heading = ARKit yaw + 37 deg, compass noisy +-4 deg, calibration high (5)
        let noise: [Double] = [3, -4, 1, -2, 4, 0, -3, 2, -1, 1]
        XCTAssertNil(f.heading(T: Self.camT(yawDeg: 10)))
        for (i, n) in noise.enumerated() {
            let ay = Double(i * 33 % 360)
            f.add(arkitYawDeg: ay, trueHeadingDeg: GeoHeading.wrap360(ay + 37 + n), accDeg: 5, t: Double(i))
        }
        let h = try XCTUnwrap(f.heading(T: Self.camT(yawDeg: 350)))
        XCTAssertEqual(GeoHeading.wrap180(h.deg - 27), 0, accuracy: 1.0)    // 350 + 37 = 27 (wrap)
        XCTAssertGreaterThanOrEqual(h.accDeg, GeoHeading.floorDeg)
        XCTAssertLessThan(h.accDeg, 10)
        // a disturbed compass (spread 60 deg) reports a large accuracy, never a confident heading
        var g = GeoHeading()
        for i in 0..<20 { g.add(arkitYawDeg: 0, trueHeadingDeg: Double((i * 47) % 120) - 60, accDeg: 5, t: Double(i)) }
        if let gh = g.heading(T: Self.camT(yawDeg: 0)) { XCTAssertGreaterThan(gh.accDeg, 25) }
        // offsets near 0/360 average correctly (circular mean)
        var w = GeoHeading()
        for (i, o) in [358.0, 2, 359, 1, 0, 357, 3].enumerated() { w.add(arkitYawDeg: 0, trueHeadingDeg: o, accDeg: 5, t: Double(i)) }
        XCTAssertEqual(GeoHeading.wrap180(try XCTUnwrap(w.offset).deg), 0, accuracy: 0.5)
        w.reset()
        XCTAssertNil(w.offset)
    }

    func testHeadingWindowForgetsOldSamples() {
        var f = GeoHeading()
        for i in 0..<10 { f.add(arkitYawDeg: 0, trueHeadingDeg: 100, accDeg: 5, t: Double(i)) }
        for i in 0..<10 { f.add(arkitYawDeg: 0, trueHeadingDeg: 200, accDeg: 5, t: 100 + Double(i)) }
        XCTAssertEqual(f.samples.count, 10)
        XCTAssertEqual(f.offset?.deg ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(GeoHeading.accuracyDeg(calibration: -1), nil)
        XCTAssertEqual(GeoHeading.accuracyDeg(calibration: 2), 5)
    }

    // MARK: datum

    func testDatumRoundTripAndServerConvention() throws {
        // frame +x points 30 deg north of east, origin 100 m east / 50 m north of (lat0, lon0)
        let d = GeoDatum(lat0: Self.lat0, lon0: Self.lon0, yaw: 30 * .pi / 180, t: [100, 50])
        let e = d.toENU(x: 10, y: 0)
        XCTAssertEqual(e.e, 100 + 10 * cos(.pi / 6), accuracy: 1e-9)
        XCTAssertEqual(e.n, 50 + 10 * sin(.pi / 6), accuracy: 1e-9)
        let ll = d.toLatLon(x: 123, y: -45)
        let back = d.fromLatLon(lat: ll.lat, lon: ll.lon)
        XCTAssertEqual(back.x, 123, accuracy: 1e-6)
        XCTAssertEqual(back.y, -45, accuracy: 1e-6)
        // 1 km north is ~0.009 deg of latitude
        let n = GeoDatum(lat0: Self.lat0, lon0: Self.lon0, yaw: 0).toLatLon(x: 0, y: 1000)
        XCTAssertEqual(n.lat - Self.lat0, 1000 / 110_600, accuracy: 2e-5)
        XCTAssertEqual(GeoDatum.distanceM((Self.lat0, Self.lon0), n), 1000, accuracy: 0.5)
        // server JSON (geoprior.Datum.to_json keys)
        let j: [String: Any] = ["lat0": 10.0, "lon0": 20.0, "yaw": 0.5, "t": [1.0, 2.0], "sigma_t": 1.5,
                                "yaw_known": false, "source": "gps-track", "centroid_map": [3.0, 4.0]]
        let p = try XCTUnwrap(GeoDatum(json: j))
        XCTAssertEqual(p.yaw, 0.5); XCTAssertEqual(p.t, [1, 2]); XCTAssertFalse(p.yawKnown)
        XCTAssertEqual(p.centroidMap ?? [], [3, 4])
        XCTAssertEqual(GeoDatum(json: ["lat0": 1.0, "lon0": 2.0, "yaw_deg": 90.0])?.yaw ?? 0, .pi / 2, accuracy: 1e-12)
        XCTAssertNil(GeoDatum(json: ["lat0": 1.0]))
    }
}
