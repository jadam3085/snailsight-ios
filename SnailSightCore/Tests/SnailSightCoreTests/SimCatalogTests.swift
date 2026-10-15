import XCTest
@testable import SnailSightCore

/// 9.8 spawn catalog + Sim scale + the "2× size" guard against the real catalog.json.
final class SimCatalogTests: XCTestCase {
    static let sample = """
    {"version": 1, "items": [
     {"key": "deer", "label": "Deer", "category": "animal", "group": "Wild", "symbol": "hare.fill",
      "files": {"idle": "deer_idle.usdz", "walk": "deer_walk.usdz"}, "size_m": [1.5, 1.38, 0.5], "thumb": "deer.png",
      "behaviour": {"calm": "graze", "walk_speed": 0.5, "flee_speed": 2.5, "scare_person": 1.2, "scare_robot": 1.8,
                    "flee_dist": 3.0, "run_above": 1.2}},
     {"key": "dog", "label": "Dog", "category": "animal", "group": "Pets", "symbol": "dog.fill",
      "files": {"idle": "dog_idle.usdz"}, "size_m": [0.8, 0.6, 0.3],
      "behaviour": {"calm": "stopgo", "walk_speed": 0.7, "flee_speed": 2.4, "scare_person": 0.4, "scare_robot": 1.0,
                    "flee_dist": 2.0, "run_above": 1.2}},
     {"key": "ball", "label": "Ball", "category": "object", "group": "Toys", "symbol": "circle.fill",
      "files": {"static": "ball.usdz"}, "size_m": [0.2, 0.2, 0.2],
      "physics": {"shape": "sphere", "mass_kg": 0.35, "friction": 0.5, "restitution": 0.75, "rolls": true},
      "extra_field_from_the_builder": 1},
     {"key": "beachball", "label": "Beach ball", "category": "object", "group": "Toys", "symbol": "circle",
      "files": {"static": "beachball.usdz"}, "size_m": [0.4, 0.4, 0.4],
      "physics": {"shape": "sphere", "mass_kg": 0.12, "friction": 0.4, "restitution": 0.8, "linear_damping": 0.6}},
     {"key": "mug", "label": "Mug", "category": "object", "group": "Kitchen", "symbol": "mug.fill",
      "files": {"static": "mug.usdz"}, "size_m": [0.12, 0.1, 0.09], "spawn_count": 1,
      "physics": {"shape": "cylinder", "mass_kg": 0.3, "friction": 0.5, "restitution": 0.1}}
    ]}
    """

    func catalog() throws -> SimCatalog { try SimCatalog.decode(Data(Self.sample.utf8)) }

    func testDecodeGroupsAndLookups() throws {
        let c = try catalog()
        XCTAssertEqual(c.items.count, 5)
        XCTAssertEqual(c.animals.map { $0.key }, ["deer", "dog"])
        XCTAssertEqual(c.objects.map { $0.key }, ["ball", "beachball", "mug"])
        XCTAssertEqual(c.groups(.object).map { $0.0 }, ["Toys", "Kitchen"])
        XCTAssertEqual(c.groups(.object).first?.1.count, 2)
        let ball = try XCTUnwrap(c.item("ball"))
        XCTAssertEqual(ball.size, SIMD3(0.2, 0.2, 0.2))
        XCTAssertEqual(ball.physics?.shape, .sphere)
        XCTAssertEqual(ball.physics?.rolls, true)
        XCTAssertEqual(ball.massKg, 0.35)
        XCTAssertEqual(c.item("beachball")?.physics?.linearDamping, 0.6)
        XCTAssertEqual(c.item("deer")?.clips, ["idle", "walk"])
        XCTAssertEqual(c.item("deer")?.file(clip: "walk"), "deer_walk.usdz")
        XCTAssertNil(c.item("unicorn"))
        // an animal's push mass comes from its body (deer ~ 60 kg/m³ × box)
        XCTAssertEqual(c.item("deer")!.massKg, 60 * 1.5 * 1.38 * 0.5, accuracy: 1e-9)
    }

    func testSearch() throws {
        let c = try catalog()
        XCTAssertEqual(c.search("").count, 5)
        XCTAssertEqual(c.search("ball").map { $0.key }, ["ball", "beachball"])     // "Beach ball": word prefix
        XCTAssertEqual(c.search("DO").map { $0.key }, ["dog"])
        XCTAssertEqual(c.search("kitch").map { $0.key }, ["mug"])                 // group
        XCTAssertTrue(c.search("zzz").isEmpty)
    }

    func testRecents() {
        var r = SimRecents(keys: ["a", "b", "a"], cap: 3)
        XCTAssertEqual(r.keys, ["a", "b"])
        r.used("c"); r.used("b"); r.used("d")
        XCTAssertEqual(r.keys, ["d", "b", "c"])
    }

    func testSpeciesFromCatalog() throws {
        let c = try catalog()
        XCTAssertEqual(SpeciesProfile.from(c.item("deer")!), .deer)          // the tuned 9.7 profile is kept
        let dog = SpeciesProfile.from(c.item("dog")!)
        XCTAssertEqual(dog.name, "dog")
        XCTAssertEqual(dog.calm, .stopgo)
        XCTAssertEqual(dog.walkSpeed, 0.7)
        XCTAssertEqual(dog.radius, 0.184, accuracy: 1e-9)                    // 0.23 × length 0.8
        XCTAssertEqual(SimCatalog.builtIn.animals.map { $0.key }, ["deer", "fox", "rabbit"])
    }

    // MARK: scale

    func testRobotScaledIsHalfEverything() {
        let p = RobotProfile.robosnailbob, h = p.scaled(0.5)
        XCTAssertEqual(h.length, 0.41, accuracy: 1e-9)
        XCTAssertEqual(h.width, 0.31, accuracy: 1e-9)
        XCTAssertEqual(h.height, 0.305, accuracy: 1e-9)
        XCTAssertEqual(h.wheelRadius, p.wheelRadius / 2, accuracy: 1e-9)
        XCTAssertEqual(h.maxSpeed, 0.2, accuracy: 1e-9)
        XCTAssertEqual(h.navSpeed, 0.15, accuracy: 1e-9)
        XCTAssertEqual(h.maxYawRate, p.maxYawRate)                          // turn rate unchanged
        XCTAssertEqual(h.maxStep, SimScale.minStep)                         // 3 cm would be below the mesh noise
        XCTAssertEqual(h.agentRadius, 0.5 * 0.31 + 0.06, accuracy: 1e-9)
        XCTAssertEqual(p.scaled(1), p)
    }

    /// The owner's "is there a residual 2× bug" check, as numbers: the drawn robot (RobotModel parts, scaled by the
    /// same factor in the app) against the 1.000 m bar. At 100 % the bbox is 0.82 × 0.61 × 0.62 m — the real Q6 Edge
    /// base + mast — so the bar is 1.22 robot lengths; at the default 50 % it is 2.44.
    func testRobotAgainstTheOneMetreBar() {
        let b = RobotModel.bounds(RobotModel.parts()).extents
        XCTAssertEqual(b.x / ScaleReference.lengthM, 0.82, accuracy: 1e-9)
        XCTAssertEqual(b.y, 0.61, accuracy: 1e-9)
        XCTAssertEqual(b.z, 0.62, accuracy: 1e-9)
        let s = SimScale.defaultGlobal
        XCTAssertEqual(b.x * s / ScaleReference.lengthM, 0.41, accuracy: 1e-9)
        // collision footprint at scale == drawn bbox at scale (no hidden factor between the two)
        let p = RobotProfile.robosnailbob.scaled(s)
        XCTAssertEqual(p.length, b.x * s, accuracy: 1e-9)
        XCTAssertEqual(p.width, b.z * s, accuracy: 1e-9)
        XCTAssertEqual(p.height, b.y * s, accuracy: 1e-9)
    }

    func testScaleClampsAndSteps() {
        XCTAssertEqual(SimScale.clampGlobal(0.1), 0.25)
        XCTAssertEqual(SimScale.clampGlobal(3), 1)
        XCTAssertEqual(SimScale.clampGlobal(.nan), SimScale.defaultGlobal)
        XCTAssertEqual(SimScale.effective(global: 0.5, override: nil), 0.5)
        XCTAssertEqual(SimScale.effective(global: 0.5, override: 1.25), 1.25)
        XCTAssertEqual(SimScale.effective(global: 0.5, override: 9), 2)
        XCTAssertEqual(SimScale.step(0.5, up: true), 0.75)
        XCTAssertEqual(SimScale.step(0.5, up: false), 0.35)
        XCTAssertEqual(SimScale.step(0.6, up: false), 0.5)
        XCTAssertEqual(SimScale.step(2, up: true), 2)
        XCTAssertEqual(SimScale.step(0.1, up: false), 0.1)
        XCTAssertEqual(SimScale.label(0.5), "50 %")
    }

    func testSpeciesScaled() {
        let d = SpeciesProfile.deer.scaled(0.5)
        XCTAssertEqual(d.radius, 0.175, accuracy: 1e-9)
        XCTAssertEqual(d.walkSpeed, 0.25, accuracy: 1e-9)
        XCTAssertEqual(d.fleeDist, 1.5, accuracy: 1e-9)
        XCTAssertEqual(d.scarePerson, 1.2 * 0.6, accuracy: 1e-9)           // about you: not below 60 %
        XCTAssertEqual(d.hop.upperBound, 1.5, accuracy: 1e-9)
        XCTAssertEqual(SpeciesProfile.fox.scaled(1), .fox)
        XCTAssertEqual(AnimalReach.maxStep(scale: 0.5), 0.06, accuracy: 1e-9)
        XCTAssertEqual(AnimalReach.maxStep(scale: 0.25), SimScale.minStep)
        XCTAssertEqual(AnimalReach.bodyHeights(height: 1.4).count, 3)
        let rb = AnimalReach.bodyHeights(height: 0.3)
        XCTAssertEqual(rb[0], 0.075, accuracy: 1e-9); XCTAssertEqual(rb[1], 0.195, accuracy: 1e-9)
    }

    func testKindsAndCommands() {
        XCTAssertEqual(SimKind(species: "cow"), SimKind(key: "cow", role: .animal))
        XCTAssertNil(SimKind(species: "robot"))
        XCTAssertEqual(SimCommand.available(for: SimKind(key: "cow", role: .animal)),
                       SimCommand.available(for: .deer))
        XCTAssertEqual(SimCommand.available(for: SimKind(key: "ball", role: .object)),
                       SimCommand.available(for: .block))
        XCTAssertEqual(SimKind.robot.label, "RobosnailBob")
    }

    func testRecordScaleIsOptional() throws {
        let old = #"{"id":"a","kind":"deer","behaviour":"roam","heading":0,"anchor":[0,0,0]}"#
        let r = try JSONDecoder().decode(SimEntityRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.scale)
        var n = r
        n.scale = 0.75
        let back = try JSONDecoder().decode(SimEntityRecord.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back.scale, 0.75)
    }

    // MARK: the real bundled catalog (written by tools/ilidar_build/verify_sim_assets.py)

    static var bundledURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/SimModels/catalog.json")
    }

    /// Every bundled model is real size at 100 %: the measured box matches the nominal size within 6 % (no hidden 2×),
    /// feet-to-head heights are plausible, every animal has a walk and an idle (or static) clip file, every object has
    /// physics, keys are unique.
    func testBundledCatalogSizesAndFiles() throws {
        guard let data = try? Data(contentsOf: Self.bundledURL) else {
            throw XCTSkip("catalog.json not next to the package (\(Self.bundledURL.path))")
        }
        let c = try SimCatalog.decode(data)
        XCTAssertGreaterThanOrEqual(c.animals.count, 10)
        XCTAssertGreaterThanOrEqual(c.objects.count, 12)
        XCTAssertEqual(Set(c.items.map { $0.key }).count, c.items.count)
        for it in c.items {
            let s = it.size
            XCTAssertEqual(it.sizeM?.count, 3, it.key)
            XCTAssertTrue(s.x > 0.03 && s.y > 0.03 && s.z > 0.01, "\(it.key) size \(s)")
            if let n = it.nominal {
                if let l = n.lengthM { XCTAssertEqual(s.x / l, 1, accuracy: 0.06, "\(it.key) length \(s.x) vs \(l)") }
                if let h = n.heightM { XCTAssertEqual(s.y / h, 1, accuracy: 0.06, "\(it.key) height \(s.y) vs \(h)") }
            }
            let files = it.files ?? [:]
            for f in files.values { XCTAssertTrue(f.hasSuffix(".usdz"), "\(it.key) \(f)") }
            if it.isAnimal {
                XCTAssertNotNil(it.behaviour, it.key)
                XCTAssertTrue(files["idle"] != nil || files["static"] != nil, "\(it.key) has no idle/static clip")
                XCTAssertTrue(s.x < 3 && s.y < 2.5, "\(it.key) too big: \(s)")
            } else {
                XCTAssertNotNil(it.physics, it.key)
                XCTAssertNotNil(files["static"], it.key)
                XCTAssertGreaterThan(it.physics?.massKg ?? 0, 0, it.key)
            }
        }
    }
}
