# AGENTS guide

This document provides instructions for coding agents working in this repository, containing the source code for Ejectify.

## About Ejectify

Ejectify is a macOS utility that helps users avoid “Disk Not Ejected Properly” warnings and potential data corruption by automatically unmounting external volumes before the system or display goes to sleep and remounting them after it wakes up. From its menu bar interface, users can enable or disable automatic (un)mounting and choose which specific volumes should be handled. Ejectify supports multiple trigger conditions, such as when the screensaver starts, when the screen locks, when the display goes to sleep, or when the system sleeps.  ￼

The app’s configuration view lists connected external disks and lets users select or deselect volumes for automatic handling. Users can also choose options like forceful unmounting and set an optional delay before remounting after wake. Once configured, Ejectify runs quietly in the background from the menu bar, monitoring sleep and wake events and performing the appropriate actions on the selected volumes.  ￼

Ejectify can be obtained either as a prebuilt macOS app from ejectify.app or by building the open-source code from its GitHub repository. The repository is licensed under MIT and includes the full source code, enabling users to inspect or modify the implementation if desired.  ￼

This automatic unmount and remount process reduces the risk of external drive corruption and eliminates the need for manual ejection before sleep, simplifying the workflow for users who frequently connect external storage to their Macs.  ￼

## Coding instructions

### General instructions

- Use Swift 6.2 or later, using modern Swift concurrency.
- Do not introduce third-party libraries without asking first.
- Use [XcodeBuildMCP](https://www.xcodebuildmcp.com) to build and/or test the project, never `xcodebuild`.
- Document code with concise descriptions above non-obvious functions and properties using `///`. Add inline comments (`//`) for non-obvious logic within function bodies. When updating code, also update documentation.
- Maintain consistency with existing architecture and naming conventions already used in this repository.