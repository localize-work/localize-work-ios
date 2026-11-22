# LocalizeWork for iOS

The native iOS SDK for [localize.work](https://localize.work). It downloads your
project's published translations, keeps them on the device, and gives your app a
string for a key. The strings bundled in your app are the fallback, so the app
always has something to show: on the first launch, offline, and for a key that
is not published yet.

- Translations you publish reach installed apps without an App Store release.
- Strings are read from memory. Looking one up never waits for the network.
- A release is used only when all of it has arrived. The app never shows half
  of one release and half of another.
- No dependencies, no analytics, nothing about the device or the user is sent.

## Requirements

iOS 15, macOS 12, tvOS 15 or watchOS 8, and Swift 5.9 (Xcode 15) or newer.

## Install

In Xcode choose **File › Add Package Dependencies…** and enter:

```
https://github.com/localize-work/localize-work-ios
```

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/localize-work/localize-work-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LocalizeWork", package: "localize-work-ios"),
    ]),
]
```

## Quick start

Configure the SDK once, as early as you can in the app's launch:

```swift
import LocalizeWork

@main
struct MyApp: App {
    init() {
        Localize.configure(LocalizeConfiguration(
            projectSlug: "my-app",   // your project's slug
            fallbackLocale: "en"     // your project's source language
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

`configure` loads the release saved on the device before it returns, then
downloads the latest release in the background.

Look strings up anywhere, from any thread:

```swift
let localize = Localize.shared

localize.string("nav.home")                          // "Home"
localize.string("greeting", ["name": "Ann"])         // "Hello, Ann!"
localize.string("items", count: 3)                   // "3 items"
localize.string("pay", namespace: "checkout")        // a key of another namespace
localize.string("promo.title", fallback: "Welcome")  // used if nothing has the key
```

## How it works

localize.work publishes each release as a set of files that never change, plus
one small file that names the current release:

```
https://cdn.localize.work/{projectSlug}/latest.json                          →  { "version": "v12" }
https://cdn.localize.work/{projectSlug}/{version}/{locale}/{namespace}.json  →  the strings
```

On a refresh the SDK:

1. reads `latest.json` once, to learn the version;
2. downloads every file it needs from that one version;
3. saves the release to the device and starts using it, only when every file
   has arrived.

If anything fails on the way, the release that was in use stays in use and
`refresh()` throws. A publish that lands while a refresh is running is picked
up by the next refresh, as a whole.

## Configuration

```swift
LocalizeConfiguration(
    projectSlug: "my-app",
    locale: "en-FI",
    fallbackLocale: "en",
    namespaces: ["common", "checkout"],
    defaultNamespace: "common",
    version: nil,
    updatePolicy: .immediately
)
```

| Option | Default | Meaning |
|---|---|---|
| `projectSlug` | required | Your project's slug. |
| `locale` | the device's first preferred language | The language to show, as a BCP 47 code: `en`, `et`, `en-FI`. Spell it the way your project does (see below). |
| `fallbackLocale` | none | Where a string is looked up when `locale` does not have it. Set it to your project's source language. |
| `namespaces` | `["translation"]` | The namespaces to download. |
| `defaultNamespace` | the first of `namespaces` | The namespace of a lookup that names none. |
| `version` | none (follow the latest) | A release to stay on, such as `"v12"`. The SDK then never reads `latest.json`, and never uses a saved release of another version. |
| `updatePolicy` | `.immediately` | When a downloaded release starts being used: `.immediately`, or `.nextLaunch`. |
| `cdnBaseURL` | `https://cdn.localize.work` | Where the files are served from. |
| `requestTimeout` | 15 seconds | How long a request may wait for data. |
| `bundle` | `.main` | The bundle whose string tables are the fallback. |
| `transport` | `URLSessionTransport()` | How requests are made. Replace it in tests. |
| `cacheDirectory` | a folder in Application Support | Where releases are saved. |

### Which languages are downloaded

A string is looked up in the locale, then in each shorter form of it, then in
the fallback locale and its shorter forms. For `locale: "en-FI"` and
`fallbackLocale: "et"` that is `en-FI`, `en`, `et`. Every namespace is
downloaded for each of them. `configuration.localeChain` shows the list.

A locale is requested from the CDN as it is written, with only its letter case
corrected (`en_fi` becomes `en-FI`), anything after the region that a device
adds dropped, and the three codes older systems still report replaced (`iw`,
`in`, `ji` become `he`, `id`, `yi`). So spell `locale` and `fallbackLocale`
the way your project's languages are spelled: a project with `sr-Latn-RS` does
not answer to `sh-RS`.

A regional locale such as `en-FI` usually holds only the few strings that
differ from `en`, and often has no file at all for a namespace. That is normal:
a file the release does not have counts as empty, and the strings come from
`en`.

To change the language while the app runs, call `Localize.configure` again with
the new `locale`. The instance it replaces stops: a download it still has
under way is dropped (its `refresh()` throws `replaced`), so it cannot save
over the new one.

A release is used whole or not at all. When the language has changed since the
release on the device was saved, that release has no files for the new
language, so the app shows its bundled strings until the files have been
downloaded. They are fetched from that same release first, so the change of
language works even while the newest release cannot be reached. Files already
downloaded for a release are kept with it: going back to a language the app
used before needs no download.

### Applying updates

With `.immediately` a release is used as soon as it is downloaded, so text can
change while the app is open. With `.nextLaunch` the download is saved and used
from the next launch, and nothing changes under a running app. On the very
first launch that means bundled strings until the second launch.

A change of language does not end the run, and by itself never changes which
release the app shows:

1. The release a run shows is decided when the app starts: the saved release
   if it is whole for the language, otherwise none. With `.nextLaunch` it
   changes only at the next launch, also after `Localize.configure` is called
   again. A run that started with no release shows bundled strings to its end.
2. After a change of language, the files that release lacks for the new
   language are fetched from that same release and added to it, since no text
   the app already shows from it changes. This needs neither the newest
   release nor `latest.json` to be reachable.
3. A newer release is handled as always: with `.nextLaunch` it waits for the
   next launch, with `.immediately` it is used once it is complete. If it
   cannot be downloaded, `refresh()` throws, and step 2 still holds.

When the release has no files for the new language at all, the app shows its
bundled strings until the next launch. A regional locale such as `en-FI` needs
no file of its own for this: the release's `en` texts are enough.

## Looking up strings

### Keys

A key is a path of names joined by dots. `nav.home` is `home` inside `nav`:

```json
{ "nav": { "home": "Home" } }
```

Keys are found the way [i18next](https://www.i18next.com) finds them, so an iOS
app and a web app can share one project.

A project can hold both a key `a` and a key `a.b`. JSON cannot nest something
under a text, so localize.work publishes `a.b` at the top of the file under its
whole name: `{ "a": "…", "a.b": "…" }`. The SDK finds it there. You look both
keys up as usual.

An empty text is a text: a key published with an empty value returns `""`. A
key that is not in a file at all is looked up in the next locale.

### Plurals

Pass `count:` for a string that depends on a number:

```swift
localize.string("items", count: 1)   // "1 item"
localize.string("items", count: 5)   // "5 items"
```

A plural key is published as one text per plural form, named with the form as
a suffix:

```json
{ "items_one": "{{count}} item", "items_other": "{{count}} items" }
```

For a count the SDK tries, in each locale's file in turn, as i18next does:

1. `items_zero`, when the count is 0;
2. `items_<form>`, the form the language uses for that count
   (`one`, `two`, `few`, `many`, `other`);
3. `items`.

A file that has none of them leaves the key to the next locale. So a regional
locale that overrides only `items_other` still gets `items_one` from its base
language. Only when no locale has the form or the plain key is a locale's
`items_other` used, as a last resort.

The form is chosen by the language of the file being read. If the Russian file
lacks a key and the English one answers, the English rule picks the form.

### Placeholders

```swift
localize.string("greeting", ["name": "Ann"])               // "Hello, {{name}}!"
localize.string("inbox", ["name": "Ann"], count: 2)        // "{{name}} has {{count}} messages"
```

- `{{name}}` is replaced by the value given for `name`. Spaces inside the
  braces are allowed: `{{ name }}`.
- `{{count}}` is the `count:` you passed.
- `{{price, currency}}` is replaced by the value of `price`. The format name
  after the comma is ignored: format the value yourself before passing it.
- A placeholder you gave no value for stays as written.
- Values are inserted as they are. Nothing is escaped.

To build the values at run time, use `LocalizeArguments([("name", name)])`.

### When nothing has the key

In order:

1. the string bundled in your app (see below);
2. the `fallback:` you passed;
3. the key itself.

## Bundled strings

Ship your strings inside the app as well, so the first launch and a device that
is offline have text to show. Export an **Xcode String Catalog** from
localize.work and add the `.xcstrings` files to your app target: there is one
file per namespace, named after it.

When the release has no text for a key, the SDK asks the bundle for the same
key, first in the table named after the namespace, then in the default table
(`Localizable`).

The catalog writes placeholders as format specifiers, which have positions
instead of names. The SDK fills them like this:

- The values go into `%1$@`, `%2$@`, … **in the order you wrote them**. The
  export numbers them in the order they appear in the source-language text, so
  list them in that order: for "From {{from}} to {{to}}" write
  `["from": a, "to": b]`.
- `count:` goes where the string reads a number (its plural variations, or a
  `%lld`), wherever that is among the other values.
- A string looked up without values or a count is returned as it is.

A bundled string may also be written with `{{name}}` placeholders, and is then
filled like a published one.

The plural form of a bundled string follows the language the string is written
in. Bundled strings come in the language iOS picks for your app, which can
differ from `locale` if you set that yourself.

## Updating the screen when a release arrives

When a downloaded release starts being used, the SDK tells you in two ways. Use
whichever fits.

SwiftUI, with the stream of versions:

```swift
struct ContentView: View {
    @State private var release = Localize.shared.version

    var body: some View {
        Text(Localize.shared.string("nav.home"))
            .id(release)
            .task {
                for await version in Localize.shared.updates {
                    release = version
                }
            }
    }
}
```

UIKit, with a notification, posted on the main thread:

```swift
NotificationCenter.default.addObserver(
    forName: Localize.didUpdateNotification, object: nil, queue: .main
) { _ in
    // set the labels again
}
```

To check for a new release yourself, for example when the app comes back to the
foreground:

```swift
try await Localize.shared.refresh()
```

It returns `.updated`, `.upToDate` or `.pendingNextLaunch`, each with the
version. A refresh that finds nothing new costs one small request.

## Offline behaviour

- The last complete release is saved on the device, per project. It is loaded
  when the SDK is configured, before `configure` returns, so strings are there
  at once with no network.
- A saved release is used only when it is the one the configuration asks for:
  it has every file the current language needs, and with a pinned `version` it
  is that version. Otherwise the app shows bundled strings until a refresh
  succeeds.
- A pinned `version` that is not published yet makes `refresh()` fail (HTTP
  404) and saves nothing, so the release is picked up once it exists.
- When a newer release is saved, older ones are deleted.
- A saved release that cannot be read (a damaged or half-written file) is
  deleted and treated as absent. The app shows bundled strings until the next
  download.
- A failed refresh changes nothing: not what is shown, and not what is saved.
- Releases are saved in the app's Application Support folder (Caches on tvOS),
  excluded from device backups.

## Errors

`refresh()` throws a `LocalizeError`. Lookups never throw.

| Error | Meaning | Try again later? |
|---|---|---|
| `projectNotPublished` | `latest.json` does not exist: nothing is published yet, or the slug is wrong. | no |
| `invalidPointer` | `latest.json` does not name a version such as `v12`. | no |
| `invalidConfiguration` | For example a `version` that is not `v` and a number. | no |
| `http(status:url:)` | The server answered with an error. | for 5xx |
| `network(url:message:)` | No answer: offline or timed out. | yes |
| `invalidFile` | A file is not the JSON it should be. | no |
| `cacheWriteFailed` | The release could not be saved (only with `.nextLaunch`). | yes |
| `notConfigured` | `Localize.shared` was used before `Localize.configure`. | no |
| `replaced` | A later `Localize.configure` call replaced this instance while it was downloading. | no |

`error.isRetryable` gives the last column. The SDK does not retry by itself:
call `refresh()` again when it suits your app.

## Plural coverage

The plural rules are those of Unicode CLDR 47, for whole numbers. That is the
release localize.work itself uses to decide which plural forms a language has,
and the Android SDK uses the same one, so all three agree on the form a count
takes. The tests
check every language below against ICU.

| Forms | Languages |
|---|---|
| `other` only | bm, bo, dz, hnj, id, ig, ii, ja, jbo, jv, kde, kea, km, ko, lkt, lo, ms, my, nqo, osa, sah, ses, sg, su, th, to, tpi, vi, wo, yo, yue, zh |
| `one` (1), `other` | af, an, asa, ast, az, bal, bem, bez, bg, brx, ce, cgg, chr, ckb, da, de, dv, ee, el, en, eo, et, eu, fi, fo, fur, fy, gl, gsw, ha, haw, hu, ia, io, jgo, jmc, ka, kaj, kcg, kk, kkj, kl, ks, ksb, ku, ky, lb, lg, lij, mas, mgo, ml, mn, mr, nah, nb, nd, ne, nl, nn, nnh, no, nr, ny, nyn, om, or, os, pap, ps, rm, rof, rwk, saq, sc, sd, sdh, seh, sn, so, sq, ss, ssy, st, sv, sw, syr, ta, te, teo, tig, tk, tn, tr, ts, ug, ur, uz, ve, vo, vun, wae, xh, xog, yi |
| `one` (0 and 1), `other` | ak, am, as, bho, bn, csw, doi, fa, ff, gu, guw, hi, hy, kab, kn, ln, mg, nso, pa, pcm, si, ti, wa, zu |
| `one`, `other`, with their own rule for `one` | ceb, fil, is, mk, tl, tzm |
| `one`, `many` (whole millions), `other` | ca, es, fr, it, lld, pt, pt-PT, scn, vec |
| `zero`, `one`, `other` | blo, ksh, lag, lv, prg |
| `one`, `two`, `other` | he, iu, naq, sat, se, sma, smi, smj, smn, sms |
| `one`, `few`, `other` | bs, cs, hr, lt, ro, shi, sk, sr |
| `one`, `few`, `many` | be, pl, ru, uk |
| `one`, `two`, `few`, `other` | dsb, gd, gv, hsb, sl |
| `one`, `two`, `few`, `many`, `other` | br, ga, mt |
| `zero`, `one`, `two`, `few`, `many`, `other` | ar, ars, cy, kw |

French and Portuguese use `one` for 0 and 1; European Portuguese (`pt-PT`) only
for 1. The older codes `in`, `iw`, `ji`, `jw`, `mo`, `sh` are understood too.
Any other language uses `one` for 1 and `other` for everything else.

## Privacy

The SDK makes plain `GET` requests for public files: no sign-in, no cookies, no
identifiers, no analytics. A request carries the project slug, the release
version, the locale and the namespace in its path, and a fixed `User-Agent`
(`localize-work-ios/0.1.0`). As with any request, the server sees the device's
IP address.

## Testing

Pass your own transport to answer requests without a network, and a temporary
folder so runs do not share saved releases:

```swift
struct FixedTransport: LocalizeTransport {
    func get(_ url: URL, timeout: TimeInterval) async throws -> LocalizeHTTPResponse {
        if url.lastPathComponent == "latest.json" {
            return LocalizeHTTPResponse(statusCode: 200, body: Data(#"{ "version": "v1" }"#.utf8))
        }
        return LocalizeHTTPResponse(statusCode: 200, body: Data(#"{ "nav": { "home": "Home" } }"#.utf8))
    }
}

let localize = Localize(configuration: LocalizeConfiguration(
    projectSlug: "my-app",
    locale: "en",
    transport: FixedTransport(),
    cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
))
try await localize.refresh()
```

`Localize(configuration:)` creates an instance of your own and downloads nothing
until you call `refresh()`.

## Limits of 0.1.0

- **Whole-number counts only.** `count:` is an `Int`. Plural forms for decimal
  numbers (1.5) are not supported.
- **Cardinal plurals only.** No ordinals ("1st", "2nd").
- **No nesting and no formatting.** `$t(other.key)` is left as written, and the
  format in `{{value, format}}` is ignored.
- **No context variants** (`key_male`, `key_female`).
- **Values are looked up by their whole name.** `{{user.name}}` needs a value
  named `user.name`.
- **One language per instance.** Changing it means configuring again.
- **Bundled strings with several numbers.** In a bundled plural string the SDK
  passes the count as the number and every other value as text. A hand-written
  catalog entry that formats a second number inside its plural variations
  (`%1$lld of %2$lld files`) will show that number wrongly. Published strings
  are not affected.
- **No automatic retries and no periodic refresh.** Call `refresh()` when you
  want to check.
- **Reading only.** Missing keys are not reported back to localize.work.
- **No SwiftUI property wrapper yet.** Use `updates` as shown above.

## Licence

MIT. See [LICENSE](LICENSE).
