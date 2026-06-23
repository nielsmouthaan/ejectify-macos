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

### File organization instructions

- Keep the existing simple structure unless there is a clear reason to change it.
- Keep app code in `Ejectify` and privileged-helper-only code in `EjectifyPrivilegedHelper`.
- Place files in the folder that best owns the behavior: `Controller`, `Model`, `View`, `Helper`, or `Extension`.
- Put shared app/helper code in a shared app folder only when both targets compile it.
- Prefer precise type names such as `Router`, `Operator`, `Formatter`, `Observer`, or `Configuration`; avoid vague names unless they clearly fit.
- Prefer one primary Swift type per file. Small tightly coupled private helper types may stay in the same file.
- Keep resources and configuration files with the target that owns them.

### Logging instructions

- Define `Logger` instances as `private static let logger` properties on the type that uses them.
- Use `LoggingConfiguration.subsystem` for logger subsystems and derive logger categories from the concrete declaring type using the form `String(describing: ConcreteType.self)`.
- Use direct `os.Logger` interpolation and put values directly in logger calls instead of prebuilding full log messages as regular strings.
- Do not specify interpolation privacy unless explicitly requested or required for clearly sensitive values such as credentials, secrets, tokens, or personal identifiers.
- Use consistent log levels: `log` for important production breadcrumbs, `info` for extra diagnostic detail, `debug` for development-only detail, `warning` for recoverable degraded behavior, `error` for failed operations, and `fault` for likely bugs or violated invariants. Avoid `trace`, `notice`, and `critical` unless the project explicitly opts into those aliases.
