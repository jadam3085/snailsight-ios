// Seams for later phases (docs/SNAILSIGHT-REFACTOR-PLAN.md §7). Intentionally empty so the structure is in place
// without unvalidated behaviour. (P1 filled the Recorder → Recorder.swift and NetClient → NetClient.swift seams.)
import Foundation

/// P2: localization against the snailsight service (`T_arkit_site` applied to one world anchor) and the
/// per-area ARWorldMap cache. AC8 state machine lives here.
protocol Localizer: AnyObject {
    var state: String { get }        // SEARCHING / LOCALIZING / LOCALIZED / LOST
}
