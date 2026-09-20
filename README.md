# Jira Search

An [Omarchy](https://omarchy.org) bar widget for Jira Cloud. Search by text, by
JQL or by ticket ID, stack searches as filters that narrow one another, and
open any issue's metadata without leaving the bar.

![Jira Search](omarchy-jira-search.png)

Requires `curl`.

## Install

```bash
cp -r . ~/.config/omarchy/plugins/anavarre.jira-search
omarchy plugin validate ~/.config/omarchy/plugins/anavarre.jira-search
omarchy plugin enable anavarre.jira-search
omarchy-shell shell rescanPlugins
omarchy bar move anavarre.jira-search --section center
```

### Keybinding

To summon the panel without reaching for the bar, add a binding to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + J", "Jira Search", "omarchy-shell shell summon anavarre.jira-search '{}'")
```

Hyprland picks the change up on save; `SUPER + SHIFT + J` then opens the panel
with the field already focused.

## Connect

Open the widget and fill in **Site**, **Account email** and **API token**, then
*Save and connect*. Credentials are checked against the Jira API right away.
Create a token at
<https://id.atlassian.com/manage-profile/security/api-tokens>.

Once connected, the panel shows the signed-in account, with **Change
credentials** to update it and **Forget** to delete what was stored.

## Usage

Click the Jira icon in the bar (or run
`omarchy-shell shell summon anavarre.jira-search '{}'`) and start typing.

| Input | What happens |
| --- | --- |
| Three or more characters | Searches as you type (300 ms after you stop) and lists up to 20 tickets, most recently updated first |
| **Enter** | Pins what you typed as a filter chip and empties the field, so the next thing you type narrows the same list |
| A full ticket ID (`ABC-123`, any case), with no filters pinned | Skips the list and shows that issue's metadata, so you can see what it is before leaving |
| JQL (`status = Done`, `updated >= -7d`, `ORDER BY created DESC`) | Sent to Jira verbatim — press **Enter** to add it as a filter |

### Stacking filters

Every search you submit stays on screen as a chip, and the panel ANDs the chips
together into one JQL query. Search `open web` and press Enter; the chip
appears and the field clears. Type `project = WEB` and press Enter, and the
list is now every HAAS ticket mentioning open web:

```
text ~ "\"open web\"" AND (project = WEB) ORDER BY updated DESC
```

Keep going and each one narrows further. Whatever is still half-typed in the
field counts as one more filter while it is there, so the list moves as you
type and settles when you submit.

Text filters match the **exact phrase**, in order. The doubled quotes above
are the reason: JQL's own quotes only delimit a string, and Lucene then splits
what is inside into separate, stemmed words — `text ~ "open web"` also
returns a ticket that says "webinar" somewhere and "evolve" somewhere else.
The escaped inner pair is what Lucene reads as a phrase. Note that `text`
covers the summary, description **and comments**, so a match may be in a
comment rather than anywhere visible on the card.

Take a chip back out by clicking it, or by pressing **Backspace** in an empty
field to drop the last one. **Clear all** appears once there are two or more.
Filters are text or JQL, mixed freely; JQL chips are shown in italics and are
parenthesised before they are ANDed, so their own `OR`s cannot leak. A `ORDER
BY` in any chip sets the sort for the whole query; otherwise it is
`ORDER BY updated DESC`.

JQL is detected automatically (a field followed by an operator, a shape such as
`assignee in (currentUser())`, or a bare sort). Because half-written JQL is a
syntax error, JQL queries wait for Enter rather than searching as you type, and
the field tells you so. Prose still works — `what is broken` stays a text
search.

### Keys

- **Up/Down** highlight a result, **Enter** (or a click) opens it in your
  browser straight away — a result is a ticket you already picked, so it does
  not stop at the metadata card the way a blindly typed ticket ID does.
- On an issue card the cursor starts on **Open in browser**, so Enter opens it
  in your browser. **Left/Right** move between buttons, **Up** leaves the row.
- **Backspace** in an empty field removes the last filter chip.
- **Escape** steps back: out of the button row, then from an issue to its
  results, then clears the field, then the filters, then closes the panel.

## Credentials and storage

The widget uses the Jira Cloud REST API with
[basic auth](https://developer.atlassian.com/cloud/jira/software/basic-auth-for-rest-apis/)
and refuses to look anything up until the credentials verify against
`GET /rest/api/3/myself`. A 401 or 403 during a lookup returns you to the form
rather than showing a bare error.

What you save lives in `~/.config/omarchy/jira-search/` (`config` and `token`,
both `0600`, directory `0700`). The token field is masked, is never read back
into the UI, and reaches `curl` through a config file on stdin — it never shows
up in `ps` or in an argv. Leaving the token field blank keeps the token already
on file.

Environment variables and an existing `jira` CLI config still win where set, so
a current setup keeps working untouched:

| What | Resolution order |
| --- | --- |
| Site | `$JIRA_SERVER` → saved `config` → `server:` in `~/.config/.jira/.config.yml` |
| Account | `$JIRA_EMAIL` → saved `config` → `login:` in `~/.config/.jira/.config.yml` |
| API token | `$JIRA_API_TOKEN` → saved `token` file → `~/.jira-api-token` |

The widget's shell does not inherit `~/.bashrc`, so a `$JIRA_API_TOKEN`
exported there is invisible to it — that is what the form is for. The `jira`
CLI itself is not required; only its config file is read, if present.

## Uninstall

```bash
omarchy plugin disable anavarre.jira-search
omarchy plugin remove anavarre.jira-search --yes
omarchy-shell shell rescanPlugins
```

`disable` takes the widget out of the bar; `remove` deletes
`~/.config/omarchy/plugins/anavarre.jira-search`.

That leaves your credentials on disk. To remove those too — or use **Forget**
in the panel before uninstalling:

```bash
rm -rf ~/.config/omarchy/jira-search
```

Also drop the `o.bind(...)` line from `~/.config/hypr/bindings.lua` if you
added one.

## License

MIT
