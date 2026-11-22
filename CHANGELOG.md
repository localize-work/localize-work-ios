# Changelog

All notable changes to this package are listed here. Versions follow
[Semantic Versioning](https://semver.org).

## 0.1.0 - 2026-11-22

The first release.

### Added

- `Localize`: downloads a project's published release from the localize.work
  CDN, keeps it on the device, and returns the string for a key.
- `Localize.configure(_:)` and `Localize.shared` for one instance configured at
  launch; `Localize(configuration:)` for an instance of your own.
- The read algorithm of the CDN contract: `latest.json` is read once per
  refresh, every file comes from the version it names, and a release is used
  only when all of its files have arrived. A pinned `version` skips the
  pointer.
- Locale fallback: `en-FI`, then `en`, then the fallback locale and its
  shorter forms. A file a release does not have (404) counts as empty; a
  pinned version with no file at all is treated as not published yet.
- A saved release per project, loaded at start so strings are available at
  once and offline. It is used only when it has every file the current
  language needs and, with a pinned version, is that version. Older versions
  are deleted; an unreadable saved release is discarded.
- `string(_:_:count:namespace:fallback:)`: i18next key lookup, including keys
  published under their full dotted name; plural forms looked up as i18next
  does, by CLDR 47 cardinal rules for whole numbers; `{{name}}` placeholders.
- Fallback to the app's bundled strings, with the values filled into format
  specifiers and the plural form chosen from a string catalog's variations.
- `updates` (an `AsyncStream`) and `Localize.didUpdateNotification`, sent when
  a downloaded release starts being used.
- `LocalizeUpdatePolicy`: apply a download immediately, or at the next launch.
- `LocalizeTransport`, to replace the network in tests.
