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

### Logging instructions

- Define `Logger` instances as `private static let logger` properties on the type that uses them.
- Use a shared subsystem or bundle identifier constant for logger subsystems and derive logger categories from the declaring type, preferring `String(describing: Self.self)` when valid for the declaration context.
- Do not create logger instances inside functions or closures.
- Use direct `os.Logger` interpolation and put values directly in logger calls instead of prebuilding full log messages as regular strings.
- Do not specify interpolation privacy unless explicitly requested or required for clearly sensitive values such as credentials, secrets, tokens, or personal identifiers.
- Use `logger.log` for important production breadcrumbs that help diagnose user-visible behavior, lifecycle transitions, configuration changes, and operation requests or results.
- Use `logger.info` for supplemental diagnostic detail that is useful during troubleshooting but not essential as a production breadcrumb.
- Use `logger.debug` or `logger.trace` only for development-only detail that should not normally be collected.
- Use `logger.warning` for unexpected but recoverable degraded behavior, fallback paths, or conditions that may require attention but do not directly fail the requested operation.
- Use `logger.error` for failed operations, failed system or API calls, and user-requested actions that cannot be completed.
- Use `logger.fault` only for likely bugs, violated invariants, or impossible states that require immediate developer attention.
- Avoid `logger.notice` and `logger.critical` unless the project explicitly opts into those aliases.
