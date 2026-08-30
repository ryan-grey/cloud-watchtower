import Foundation
import SwiftUI

/// Every piece of mutable settings-window state.
///
/// This class exists because `@State` is banned: in the macOS 27 SDK it is a macro whose
/// plugin ships only with Xcode, and this project builds with Command Line Tools. A settings
/// window is exactly the kind of view that would otherwise be full of `@State`, so all of it
/// — the draft config, the selection, the in-flight test — lives here as `@Published` and the
/// views stay stateless. `@ObservedObject` and `@EnvironmentObject` are ordinary property
/// wrappers and compile fine.
@MainActor
final class SettingsStore: ObservableObject {

    @Published var draft: Configuration
    @Published var selection: UUID?
    @Published var profiles: [String] = []
    /// Until `~/.aws` has actually been read, an unrecognised profile is unknown rather than
    /// missing. Without this the picker labels every profile "(missing)" for the first frames
    /// after the window opens, which reads as a broken install rather than a pending read.
    @Published private(set) var profilesLoaded = false
    @Published var testMessage: String?
    @Published var testSucceeded = false
    @Published var isTesting = false

    private let state: AppState

    init(state: AppState) {
        self.state = state
        self.draft = state.config
        self.selection = state.config.targets.first?.id
        Task { await loadProfiles() }
    }

    func loadProfiles() async {
        profiles = await state.credentials.availableProfiles()
        profilesLoaded = true
    }

    /// True only once `~/.aws` has been read and the name genuinely is not in it.
    func isMissing(_ profile: String) -> Bool {
        profilesLoaded && !profiles.contains(profile)
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return draft.targets.firstIndex { $0.id == selection }
    }

    var projection: CostProjection { CostProjection.estimate(targets: draft.targets) }

    var isDirty: Bool { draft != state.config }

    // MARK: Mutations

    func add(_ recipe: RecipeID?) {
        selection = recipe.map { draft.addMetric($0) } ?? draft.addAlarm()
    }

    func addBudget() { selection = draft.addBudget() }

    func removeSelected() {
        guard let selection else { return }
        self.selection = draft.remove(selection)
    }

    func changeRecipe(at index: Int, to recipe: RecipeID) {
        guard draft.targets.indices.contains(index) else { return }
        draft.changeRecipe(draft.targets[index].id, to: recipe)
    }

    func apply() {
        state.applyConfiguration(draft)
        testMessage = nil
    }

    func revert() {
        draft = state.config
        selection = draft.targets.first?.id
        testMessage = nil
    }

    // MARK: Test connection

    func testSelected() {
        guard let index = selectedIndex else { return }
        let target = draft.targets[index]
        isTesting = true
        testMessage = nil
        Task {
            let result = await state.test(target)
            switch result {
            case .success(let summary):
                testSucceeded = true
                testMessage = summary
            case .failure(let error):
                testSucceeded = false
                testMessage = Diagnosis.explain(error, target: target)
            }
            isTesting = false
        }
    }
}

/// Turns an AWS failure into the sentence that names the fix.
///
/// The self-test already did this on the terminal — it names the IAM statement and the exact
/// ARN suffix when `DescribeBudget` is denied. IAM onboarding is the single biggest risk to
/// this product, so that diagnosis belongs in the GUI, not only in a flag most buyers will
/// never run.
enum Diagnosis {
    static func explain(_ error: Error, target: WatchTarget) -> String {
        guard let aws = error as? AWSError else { return error.localizedDescription }

        if aws.isPermissionProblem {
            switch target.kind {
            case .alarm:
                return "\(aws.localizedDescription)\n\nThe role is missing "
                     + "cloudwatch:DescribeAlarms (statement “AlarmStateReadOnly”)."
            case .budget(let accountId, let name):
                return "\(aws.localizedDescription)\n\nThe role's “BudgetReadOnly” statement "
                     + "must cover arn:aws:budgets::\(accountId):budget/\(name). A budget "
                     + "name that does not match the policy denies exactly like a missing "
                     + "permission."
            case .metricGroup:
                return "\(aws.localizedDescription)\n\nThe role is missing "
                     + "cloudwatch:GetMetricData (statement “MetricsReadOnly”)."
            }
        }

        if aws.code == "AlarmNotFound" || aws.code == "BudgetNotFound" {
            return "\(aws.localizedDescription)\n\nThe name is wrong, or it lives in a "
                 + "different region or account than this target's."
        }
        return aws.localizedDescription
    }
}
