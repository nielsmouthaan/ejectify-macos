# AGENTS guide

This document provides instructions for coding agents working in this repository, containing the source code for Ejectify.

## About Ejectify

Ejectify is a macOS utility that helps users avoid “Disk Not Ejected Properly” warnings and potential data corruption by automatically unmounting external volumes before the system or display goes to sleep and remounting them after it wakes up. From its menu bar interface, users can enable or disable automatic (un)mounting and choose which specific volumes should be handled. Ejectify supports multiple trigger conditions, such as when the screensaver starts, when the screen locks, when the display goes to sleep, or when the system sleeps.  ￼  ￼

## Coding instructions

### General instructions

- Use Swift 6.2 or later, using modern Swift concurrency.
- Do not introduce third-party libraries without asking first.
- Use [XcodeBuildMCP](https://www.xcodebuildmcp.com) to build and/or test the project, never `xcodebuild`.
- Maintain consistency with existing architecture and naming conventions already used in this repository.
- Document code with concise descriptions above type, function, and property declarations using `///`, unless the declaration name already makes its purpose and usage immediately clear. Add inline comments (`//`) for non-obvious logic within function bodies. When updating code, also update documentation where applicable.
- Always separate declarations with a blank line. Insert one empty line between every type, function, and property declaration. Also ensure a blank line exists before any documentation comment (`///`), so the comment clearly belongs to the declaration it documents and does not directly follow `{`, another declaration, or any other statement.