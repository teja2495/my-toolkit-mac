# AGENTS.md

## Project Intent
- This is a personal macOS toolkit app.
- Features are added for personal day-to-day utility.
- The app contains multiple unrelated utilities bundled into one app.

## Non-Negotiables
- Never run `git add` or `git commit` commands.
- Follow existing architecture, folder structure, and UI patterns already present in the repo.
- Keep features independent. Avoid cross-feature coupling unless there is a strong reason.

## Feature Organization
- Put standalone utilities in `Toolkit/Features/<FeatureName>/`.
- Each feature should have a focused `AppFeature` implementation with:
  - stable `id`
  - `start()`
  - `stop()`
- Keep feature-specific models/controllers in that same feature folder.

## Settings + Wiring Checklist
- Add the feature descriptor in `Toolkit/Core/App/AppBootstrapper.swift` (`availableFeatures`).
- Create/start/stop lifecycle in `AppBootstrapper.updateFeatureLifecycle()`.
- Route feature settings in `Toolkit/Settings/SettingsDetail.swift`.
- Reuse the shared settings UI components:
  - `SettingsPage`
  - `FeatureEnableToggle`
  - `SettingsCard`
  - `SettingsRow`

## Miscellaneous Bucket Rule
- Simple toggle-style behaviors and small system tweaks should go in `Toolkit/Features/Miscellaneous/`.
- If a utility grows into a larger workflow (custom data model, complex UI, or multiple behaviors), move it into its own dedicated feature module.

## State and Persistence
- Keep feature toggles and lightweight settings in `AppBootstrapper` with `@Published` + `UserDefaults`, matching existing patterns.
- Keep default values conservative and reversible.

## Permissions and Safety
- Use accessibility permission gating only for features that truly require it.
- Ensure `start()`/`stop()` are safe to call multiple times.
- When changing system-level preferences, always restore original state when disabling/stopping (as done in `MiscellaneousFeature`).
