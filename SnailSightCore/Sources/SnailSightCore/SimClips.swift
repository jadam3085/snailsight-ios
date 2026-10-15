import Foundation

/// Animation clip choice per gait, with fallbacks. Clip FILES are named by state (`deer_eat.usdz`); the pack's own
/// clip names (Quaternius Stag `AnimalArmature|Eating`, Kenney Cube Pets `eat`, Khronos fox `Survey`) are resolved
/// once at build time by tools/ilidar_build/build_phone_models.py from the candidate lists in
/// console/static/models/entities/MANIFEST.json (three vocabularies: KayKit, Quaternius `Quat_*`, `AnimalArmature|*`;
/// memory snailcop-clip-vocabulary-mismatch). Here a missing state falls back to the next candidate and finally to the
/// static pose — never to an unrelated action.
public enum SimClips {
    public static let candidates: [AnimalGait: [String]] = [
        .still: ["idle", "static"],
        .alert: ["idle", "static"],
        .graze: ["eat", "idle", "static"],
        .walk: ["walk", "idle", "static"],
        .run: ["run", "walk", "static"],
    ]

    /// Every clip file the app should try to load for a species.
    public static let allClips = ["static", "idle", "walk", "run", "eat"]

    public static func pick(_ gait: AnimalGait, available: Set<String>) -> String? {
        for c in candidates[gait] ?? ["static"] where available.contains(c) { return c }
        return nil
    }

    public static func fileName(species: String, clip: String) -> String {
        clip == "static" ? species : "\(species)_\(clip)"
    }
}
