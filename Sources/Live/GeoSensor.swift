// SnailSight 12.22 GPS / compass / barometer as weak priors on every live keyframe (server live 0.10, API §6b.13).
// - Location permission: when-in-use, asked the first time Live map starts (purpose string in project.yml). Precise
//   location is asked for temporarily (purpose key "LiveMap") when the user granted only approximate location.
// - Battery: CoreLocation runs at best accuracy ONLY while Live map is on (stopped at Live map off / background), the
//   attitude is pulled at 10 Hz from CoreMotion (no handler), the barometer is the always-cheap CMAltimeter.
// - Heading: the TRUE heading of the camera's optical axis. CoreMotion's xTrueNorthZVertical attitude gives the back
//   camera axis vs true north at a frame; the ARKit pose gives the same axis' ARKit yaw. GeoHeading keeps the offset
//   (circular mean, 60 s) and each keyframe's heading = its own ARKit yaw + offset (smooth, honest accuracy).
// - ARGeoTrackingConfiguration: availability is checked once per ~1 km at the current fix and logged
//   (`geo_tracking_available`). DECISION (12.22): not used during Live map. It is a different ARConfiguration, so using
//   it means re-running the shared ARSession: a new ARKit world (new stream id), scene reconstruction and the LiDAR
//   mesh reset (the RoomPlan trap, 88 -> 11 anchors) and no sceneReconstruction in geo tracking. Apple's imagery is
//   street-level, so yards / paths a walk explores are mostly not covered. Raw GPS + the ARKit-carried compass already
//   give the weak prior the server needs (it vetoes / places approximately, never fuses). Revisit as an explicit,
//   short outdoor "calibrate" step if the logs show `available: true` where the owner walks.
import ARKit
import CoreLocation
import CoreMotion
import SnailSightCore

final class GeoSensor: NSObject, CLLocationManagerDelegate {
    private unowned let model: AppModel
    private let lm = CLLocationManager()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private(set) var running = false
    private var last: CLLocation?
    private var baroRel: Double?
    private var heading = GeoHeading()
    private var lastSampleT: TimeInterval = 0
    private var convLogged = false
    private var geoCheckAt: CLLocation?
    private var stats = (fixes: 0, sent: 0, withHeading: 0, samples: 0, accs: [Double]())
    private var lastStats: TimeInterval = 0
    private var askedPrecise = false

    init(model: AppModel) {
        self.model = model
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = kCLDistanceFilterNone
        lm.activityType = .fitness
        lm.pausesLocationUpdatesAutomatically = false
    }

    private var now: TimeInterval { Date().timeIntervalSince1970 }

    /// The newest fix for the map (nil before the first good one).
    var latestFix: CLLocation? { last }

    // MARK: on / off (Live map)

    func setEnabled(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            let st = lm.authorizationStatus
            if st == .notDetermined { lm.requestWhenInUseAuthorization() }
            lm.desiredAccuracy = kCLLocationAccuracyBest
            lm.startUpdatingLocation()
            if CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical), motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 0.1
                motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical)
            }
            if CMAltimeter.isRelativeAltitudeAvailable() {
                altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] d, _ in
                    if let d { self?.baroRel = d.relativeAltitude.doubleValue }
                }
            }
            heading.reset()
            model.log.event("geo_on", ["auth": .string(Self.authName(st)), "precise": .bool(lm.accuracyAuthorization == .fullAccuracy),
                                       "true_north": .bool(motion.isDeviceMotionActive),
                                       "baro": .bool(CMAltimeter.isRelativeAltitudeAvailable())])
        } else {
            lm.stopUpdatingLocation()
            motion.stopDeviceMotionUpdates()
            altimeter.stopRelativeAltitudeUpdates()
            baroRel = nil
            logStats(force: true)
            model.log.event("geo_off", ["fixes": .int(stats.fixes), "sent": .int(stats.sent)])
        }
    }

    /// The ARKit world changed (new stream): the compass offset belongs to the old world.
    func worldFrameChanged() { heading.reset() }

    // MARK: per frame (main, cheap): compass vs ARKit yaw, 10 Hz

    func frame(_ f: ARFrame) {
        guard running, f.timestamp - lastSampleT >= 0.1, let dm = motion.deviceMotion else { return }
        lastSampleT = f.timestamp
        guard case .normal = f.camera.trackingState else { return }
        let r = dm.rotationRate
        guard abs(r.x) + abs(r.y) + abs(r.z) < 0.6 else { return }      // turning fast: the two clocks disagree
        guard let acc = GeoHeading.accuracyDeg(calibration: Int(dm.magneticField.accuracy.rawValue)) else { return }
        let a = dm.attitude.rotationMatrix
        let R = [a.m11, a.m12, a.m13, a.m21, a.m22, a.m23, a.m31, a.m32, a.m33]
        let g = [dm.gravity.x, dm.gravity.y, dm.gravity.z]
        guard let ax = GeoHeading.cameraAxisNorthWestUp(rotation: R, gravityDevice: g),
              let th = GeoHeading.trueHeadingDeg(northWestUp: ax.axis) else { return }
        if !convLogged {
            convLogged = true
            model.log.event("geo_heading_conv", ["transposed": .bool(ax.transposed)])
        }
        let M = f.camera.transform
        var T = [Double](repeating: 0, count: 16)
        for c in 0..<4 { for rr in 0..<4 { T[rr * 4 + c] = Double(M[c][rr]) } }
        guard let ay = GeoHeading.arkitYawDeg(T: T) else { return }
        heading.add(arkitYawDeg: ay, trueHeadingDeg: th, accDeg: acc, t: f.timestamp)
        stats.samples += 1
    }

    /// The `geo` of a keyframe with camera pose `T` (T_arkit_cam row-major), nil without a fresh, good fix.
    func geo(T: [Double]) -> LiveGeo? {
        guard running, let l = last else { return nil }
        let h = heading.heading(T: T)
        let g = LiveGeoFix.make(lat: l.coordinate.latitude, lon: l.coordinate.longitude, hAccM: l.horizontalAccuracy,
                                altM: l.altitude, vAccM: l.verticalAccuracy, fixTime: l.timestamp.timeIntervalSince1970,
                                now: now, heading: h, baroRelM: baroRel)
        if g != nil {
            stats.sent += 1
            if h != nil { stats.withHeading += 1 }
        }
        logStats(force: false)
        return g
    }

    private func logStats(force: Bool) {
        guard force || now - lastStats >= 60, stats.fixes > 0 || stats.samples > 0 else { return }
        lastStats = now
        let accs = stats.accs.sorted()
        var ev: [String: LogValue] = ["fixes": .int(stats.fixes), "sent": .int(stats.sent),
                                      "with_heading": .int(stats.withHeading), "heading_samples": .int(stats.samples),
                                      "baro": .bool(baroRel != nil)]
        if !accs.isEmpty { ev["h_acc_p50"] = .double(accs[accs.count / 2]); ev["h_acc_min"] = .double(accs[0]) }
        if let o = heading.offset { ev["heading_spread_deg"] = .double((o.spreadDeg * 10).rounded() / 10); ev["heading_acc_deg"] = .double(o.accDeg) }
        if let b = baroRel { ev["baro_rel_m"] = .double((b * 100).rounded() / 100) }
        model.log.event("geo_stats", ev)
        stats.accs.removeAll(keepingCapacity: true)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        model.log.event("geo_auth", ["auth": .string(Self.authName(st)),
                                     "precise": .bool(manager.accuracyAuthorization == .fullAccuracy)])
        guard running else { return }
        if st == .authorizedWhenInUse || st == .authorizedAlways {
            manager.startUpdatingLocation()
            if manager.accuracyAuthorization == .reducedAccuracy, !askedPrecise {
                askedPrecise = true
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "LiveMap")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        last = l
        stats.fixes += 1
        stats.accs.append(l.horizontalAccuracy)
        if stats.accs.count > 600 { stats.accs.removeFirst(300) }
        model.islands.fixChanged(l)
        checkGeoTracking(l)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        model.log.event("geo_error", ["error": .string(error.localizedDescription)])
    }

    // MARK: ARKit geo tracking availability (logged; decision in the header)

    private func checkGeoTracking(_ l: CLLocation) {
        guard l.horizontalAccuracy <= 100 else { return }
        if let p = geoCheckAt, p.distance(from: l) < 1000 { return }
        geoCheckAt = l
        let supported = ARGeoTrackingConfiguration.isSupported
        let acc = l.horizontalAccuracy
        guard supported else {
            model.log.event("geo_tracking_available", ["supported": .bool(false), "available": .bool(false),
                                                       "use": .bool(false), "why": .string("device not supported")])
            return
        }
        ARGeoTrackingConfiguration.checkAvailability(at: l.coordinate) { [weak self] ok, err in
            DispatchQueue.main.async {
                var ev: [String: LogValue] = ["supported": .bool(true), "available": .bool(ok), "h_acc_m": .double(acc),
                                              "use": .bool(false),
                                              "why": .string("decision 12.22: needs a re-run of the shared ARSession (new world + mesh reset); street imagery only")]
                if let err { ev["error"] = .string(err.localizedDescription) }
                self?.model.log.event("geo_tracking_available", ev)
            }
        }
    }

    static func authName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "when_in_use"
        @unknown default: return "unknown"
        }
    }
}
