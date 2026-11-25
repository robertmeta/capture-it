# Meeting titles

`capture-it teams` automatically checks the selected app's accessible window
titles when Accessibility access is already granted. It reads only that PID's
window titles; it does not walk chat contents, click controls or inspect private
app files. Audio capture works without this permission.

```sh
capture-it doctor
capture-it setup-accessibility
capture-it teams

# Supply a confirmed title when the app hides it or several windows are open.
capture-it teams --title 'Weekly Planning'
```

`doctor --json` includes `accessibilityTrusted`. The setup command requests
access; if needed, enable the terminal or CLI in System Settings → Privacy &
Security → Accessibility, then rerun doctor. The first request may return exit 2
while approval is pending. Ordinary recording never opens this permission prompt.

A dedicated worker samples every two seconds, with 150 ms messaging timeouts
and at most eight windows. Slow, denied or unavailable Accessibility calls do
not enter the audio callback, assembler, WAV writer or speech queues. It does
not wait for metadata during shutdown. This uses Apple's public
[AXUIElement APIs](https://developer.apple.com/documentation/applicationservices/axuielement_h).

## Provenance and uncertainty

An accessible window title can describe a meeting, a chat, a browser tab or
another app view. Capture-it therefore records it as an **unverified candidate**.
It removes common app-name suffixes, excludes known generic titles and accepts
only one distinct candidate. Multiple candidates produce `ambiguous`; absent or
generic titles remain `unknown`. This is a conservative window-title reader,
not a Teams/Slack meeting detector or a calendar-subject lookup.

`session.json` and hook `input.json` include the same optional `meeting` object:

```json
{
  "meeting": {
    "title": "Weekly Planning",
    "source": "accessibility-window-title",
    "verified": false,
    "status": "candidate",
    "windowTitle": "Weekly Planning | Microsoft Teams"
  }
}
```

For `--title`, source is `explicit`, status is `provided` and `verified` is
`true`, meaning the user supplied the title. This does not imply independent
calendar verification. Optional strings are omitted when unavailable. Other
statuses are `permission-required`, `unavailable`, `unknown` and `ambiguous`.
Hooks should retain this provenance when generating notes.

The selected app queries, local date and occurrence determine the output
folder. Multi-app recordings accept an explicit title. Automatic window-title
detection applies to a single selected app.

The native title journey exercises actual app windows, a competing unrelated
app, an explicit override and a generic title. Actual meeting-title exposure
still depends on the app/version and its current UI; a Teams meeting was not
joined for this test.
