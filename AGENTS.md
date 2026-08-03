# AGENTS guide

This document provides instructions for coding agents working in this repository, containing the source code for Ejectify.

## About Ejectify

Ejectify is a macOS menu bar utility that helps users avoid “Disk Not Ejected Properly” warnings and potential data corruption by automatically unmounting selected ejectable volumes before the display turns off or the system starts sleeping. It remounts previously unmounted volumes when the Mac is ready again.

## Coding instructions

### General instructions

- Use Swift 6 and prefer modern Swift concurrency for new code. Use pragmatic bridging with queues, locks, or completion handlers when working with older system APIs.
- Do not introduce third-party libraries without asking first.
- Maintain consistency with existing architecture and naming conventions already used in this repository.
- For strings that mirror macOS system UI, notifications, or alerts, match Apple’s terminology in each language instead of inventing custom wording.
- For disk ejection warnings specifically, use `/System/Library/Frameworks/DiskArbitration.framework/Versions/A/Resources/Localizable.loctable` as the source of truth.
- Document code with concise descriptions above type, function, and property declarations using `///`, unless the declaration name already makes its purpose and usage immediately clear. Add inline comments (`//`) for non-obvious logic within function bodies. When updating code, also update documentation where applicable.
- Insert a blank line before every documented declaration so each `///` comment is visually separated from the preceding code and clearly attached to the declaration it documents. Also insert a blank line between declarations when at least one of the two declarations is documented. Consecutive undocumented property declarations may remain adjacent without blank lines.
- Use [XcodeBuildMCP's CLI](https://github.com/getsentry/XcodeBuildMCP/blob/main/docs/CLI.md) (`xcodebuildmcp`) for building, testing and running the project. Use "Ejectify" as scheme and "./Ejectify.xcodeproj" as project path.
- When notarizing Ejectify, use the `ejectify-notary` notarytool keychain profile, for example `./release/release.sh --notary-profile ejectify-notary`.

### Changelog instructions

- Build each release entry from the user-facing changes since the previous released version or tag, not from the most recent commit alone.
- Describe shipped features, fixes, compatibility changes, and support-relevant diagnostics improvements in terms of their user-visible outcome.
- Exclude documentation-only changes, repository assets that are not bundled with the app, tests, refactors, and internal development or release tooling unless they materially change the installed app's behavior.

### File organization instructions

- Keep the existing simple structure unless there is a clear reason to change it.
- Keep app code in `Ejectify` and privileged-helper-only code in `EjectifyPrivilegedHelper`.
- Place files in the folder that best owns the behavior: `Controller`, `Model`, `View`, `Helper`, or `Extension`.
- Put shared app/helper code in a shared app folder only when both targets compile it.
- Prefer precise type names such as `Router`, `Operator`, `Formatter`, `Observer`, or `Configuration`; avoid vague names unless they clearly fit.
- Prefer one primary Swift type per file. Small tightly coupled private helper types may stay in the same file.
- Keep resources and configuration files with the target that owns them.

### Logging instructions

- Add logs for support-relevant workflow milestones, decisions, state changes, degraded behavior, and failures. Log each outcome once where it is known, and skip noisy routine interactions.
- Keep logging lightweight. Do not add abstractions, state, or substantial processing solely for low-severity logs; prefer concise inline metadata and omit fields that require extra plumbing without clear diagnostic value.
- Use the centralized `Log.category` facade instead of defining raw `Logger` instances in individual types.
- Log categories represent stable app workflows or subsystems, not concrete Swift types. Reuse an existing category unless a new one materially improves support/debug filtering. Define new categories centrally on `Log`, use stable readable category strings, and never include user content, IDs, URLs, filenames, or dynamic values in category names.
- Use `.debug` for verbose details useful while developing or investigating a specific issue. Debug events are written to OSLog but excluded from persisted Diagnostics by default; opt in only when the event is genuinely useful in support reports.
- Use `.info` for supplemental diagnostic breadcrumbs, `.log` for important production workflow milestones, `.warning` for recoverable degraded behavior, `.error` for failed operations, and `.fault` for likely bugs or violated invariants. Avoid `trace`, `notice`, and `critical` unless the project explicitly adopts those aliases.
- When an `Error` value is available and privacy-safe, use `Log.category.error(error, message:)` or `Log.category.fault(error, message:)` so Diagnostics preserves the underlying error. Use the message-only overload when an error description may contain private paths or user-authored content.
- Every failed operation must be logged at `warning`, `error`, or `fault`; do not record failures only at `debug` or `info`.
- Prefer domain events with concise `key=value` metadata. Use stable correlation fields where useful, but do not log secrets, tokens, user-authored volume names, private file paths, or fallback identifiers containing user or device metadata.
- Main-app `Log` events write to both OSLog and persisted Diagnostics. Privileged-helper `Log` events write to OSLog and are included through the helper unified-log chapter in diagnostics reports.
- Query unified logs only for the privileged helper and relevant non-app macOS services such as Disk Arbitration, launchd, and ServiceManagement. Do not query main-app OSLog events because Diagnostics already includes them.
