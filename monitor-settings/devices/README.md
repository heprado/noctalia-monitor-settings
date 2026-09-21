# Device name overrides

`ddcutil` only knows the generic MCCS spec's names for VCP feature values. Manufacturers are free to (and often do)
use their own codes for things like picture-mode presets -- `ddcutil` has no way to know these, so the plugin falls
back to showing the raw value (`0x11`) instead of a real name.

This folder lets you fix that without touching any plugin code: drop a JSON file here named after the
**manufacturer**, not the exact model -- run `ddcutil detect` and look for the 3-letter VESA PNP id on the
`Mfg id:` line (e.g. `Mfg id: AUS - UNK` -> `AUS.json` for ASUSTeK). The plugin picks it up automatically on the
next refresh, and it then applies to every monitor from that manufacturer, not just the one you tested on.

## Format

One file per manufacturer PNP id, keyed by feature code (lowercase hex), then by value code (lowercase hex):

```json
{
  "dc": {
    "0b": "Scenery Mode",
    "0d": "Racing Mode"
  }
}
```

## Finding your monitor's real names

1. Open the monitor's own OSD menu and note the option you want to name (e.g. "Racing Mode" under GameVisual).
2. Find the feature code controlling it -- for a picture-mode preset it's almost always `DC` (Display Mode); run
   `ddcutil vcpinfo dc --verbose` if unsure which feature a setting maps to.
3. Change the OSD setting, then run `ddcutil getvcp dc` (or the relevant code) -- the hex value it reports is the
   value code for that option.
4. Repeat for each option, then add them all to `<PNP-id>.json` under that feature's code.

## Confirmed vs. referenced

A manufacturer's whole lineup shares one file, but not every value has been checked on every model from that
manufacturer. Two optional top-level metadata keys track that -- both are inert at runtime (`classifyFeature` only
ever looks up 2-hex-digit feature/value codes, so any other key is ignored) and exist purely so the next reader
knows how much to trust an entry:

- `"_verified_on": ["VG278QR"]` -- the exact model(s) someone actually changed the setting on and read back with
  `ddcutil getvcp`, per the steps above. A value under a manufacturer file with no matching `_verified_on` entry for
  your model might still be right (many manufacturers reuse the same codes across a lineup), but isn't guaranteed to
  be.
- `"_source": "<url>"` -- copied from a third-party doc/wiki instead of tested against real hardware at all. Treat
  these as a starting point, not ground truth: if you own a monitor from that manufacturer, verify a few values,
  then move the confirmed ones into `_verified_on` (or drop `_source` if the whole file checks out).

Never invent a mapping with neither key -- a wrong name is worse than the honest `0xNN` fallback, since it looks
authoritative and isn't.

## Contributing

Missing your manufacturer? Open a PR adding `<PNP-id>.json` here -- one file per manufacturer keeps entries easy to
review. Tag new values `_source` or `_verified_on` as above so reviewers know which they're getting.
