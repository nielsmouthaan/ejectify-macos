# AGENTS guide

This document provides instructions for coding agents working in this repository, containing the source code for Ejectify.

## About Ejectify

Ejectify is a macOS menu bar utility that helps users avoid “Disk Not Ejected Properly” warnings and potential data corruption by automatically unmounting selected ejectable volumes before the display turns off or the system starts sleeping. It remounts previously unmounted volumes when the Mac is ready again.

## Coding instructions

### General instructions

- Use Swift 6, using modern Swift concurrency.
- Do not introduce third-party libraries without asking first.
- Maintain consistency with existing architecture and naming conventions already used in this repository.
- For strings that mirror macOS system UI, notifications, or alerts, use the official Apple localization from the corresponding system language resources instead of writing custom translations. For disk ejection warnings specifically, use `/System/Library/Frameworks/DiskArbitration.framework/Versions/A/Resources/Localizable.loctable` as the source of truth.
- Document code with concise descriptions above type, function, and property declarations using `///`, unless the declaration name already makes its purpose and usage immediately clear. Add inline comments (`//`) for non-obvious logic within function bodies. When updating code, also update documentation where applicable.
- Insert a blank line before every documented declaration so each `///` comment is visually separated from the preceding code and clearly attached to the declaration it documents. Also insert a blank line between declarations when at least one of the two declarations is documented. Consecutive undocumented property declarations may remain adjacent without blank lines.
- Use [XcodeBuildMCP's CLI](https://github.com/getsentry/XcodeBuildMCP/blob/main/docs/CLI.md) (`xcodebuildmcp`) for building, testing and running the project. Use "Ejectify" as scheme and "./Ejectify.xcodeproj" as project path.
