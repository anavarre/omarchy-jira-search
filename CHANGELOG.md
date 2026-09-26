# Changelog

Each release names the source it describes: the manifest `version`, the git
tag, and the full commit SHA it was tested at, together with the Omarchy
version it was checked on. Nothing is claimed beyond what is listed under
**Tested**.

## 1.0.0 — unreleased

First release.

### Features

- Centered, keyboard-driven search panel for Jira Cloud, summoned by
  keybinding; no bar widget.
- Search by text (exact phrase), by JQL, or by ticket ID; a full ticket ID
  opens that issue's metadata card.
- Stack searches as filter chips that are ANDed into one JQL query, with a
  shared `ORDER BY`.
- Built-in JQL examples on **?** / **F1**.
- `summon` payload `{"query": "..."}` prefills the field.
- Credentials form verified against `GET /rest/api/3/myself`; the API token is
  kept in the system keyring through `secret-tool` when available, otherwise in
  a `0600` file.

### Safety

- Remote text is rendered as plain text.
- Only https sites are accepted, and browse links open only on the configured
  site.
- Requests have a 20 s deadline and a 1 MB response cap; curl ignores
  `~/.curlrc` and receives the token on stdin, never in argv.
- Settings writes and deletes are checked before success is reported.
- Pending requests are released whenever the panel closes.

### Tested

- Portable: `./tests/run` (manifest check and 42 Node tests against fake
  `curl` and `secret-tool`), in CI on ubuntu-latest.
- Live shell, install, update and removal: to be recorded here, with the
  Omarchy version and full plugin SHA, before `v1.0.0` is tagged.
- Not covered yet (confirm or drop before tagging): multi-monitor placement,
  ARM64. Jira Server and Data Center are unsupported.
