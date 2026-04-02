# Changelog

## 2.0.1

- Added external non-ejectable volumes to the discovery list so more removable media is surfaced consistently.

## 2.0.0

- Added a first-launch onboarding flow with improved presentation, localized copy, and clearer elevated-permissions guidance.
- Introduced privileged helper routing and refined disk operation handling, remount retries, sleep/wake behavior, and logging.
- Added a global shortcut for `Unmount all`.
- Improved packaging, notarization, Sparkle update handling, and release tooling.
- Expanded and corrected localizations, including alignment with Apple system wording for disk ejection strings.

## 1.2.2

- Added support for internal but ejectable volumes such as SD cards.
- Fixed a code signing issue in the release process.
- Added Turkish and Brazilian Portuguese localizations and updated German translations.
- Cleaned up warnings, versioning, and documentation updates around the release.

## 1.2.1

- Fixed a build issue affecting the release.
- Restricted the volume list to external volumes.
- Added extra logging to help debug disk and sleep behavior.
- Added an FAQ section and enabled Italian translations.
- Updated French and Spanish localizations and refreshed the README.

## 1.2.0

- Added `Unmount all`.
- Added a forced unmount option for managed volumes.
- Added a delay before remounting volumes.
- Expanded the app's localization coverage, including Arabic.

## 1.1.0

- Updated Hindi translations.

## 1.0.0

- Initial release of Ejectify.
