.pragma library

// Jira keys are PROJECT-123. The field is uppercased on submit, so a lowercase
// typed key still resolves.
var keyPattern = /^[A-Z][A-Z0-9_]+-[0-9]+$/

var issueFields = "summary,status,issuetype,priority,assignee,reporter,project,updated"

// The list view shows less than the detail view, so it asks for less.
var searchFields = "summary,status,issuetype,priority,assignee,updated"
var searchLimit = 20

// Basic auth for Jira Cloud REST APIs: Authorization: Basic base64(email:token).
// https://developer.atlassian.com/cloud/jira/software/basic-auth-for-rest-apis/
//
// Credentials are resolved in the shell, never held in QML: the site and
// account come from the env or the jira-cli config, and the API token from
// $JIRA_API_TOKEN or a token file. curl reads `user =` from a config file on
// stdin (-K -) so the token never appears in argv or in `ps`.
//
// Exit codes: 10 no site, 11 no account, 12 no token, 20 request failed.
// On success the body is printed with the HTTP status on its own last line.
var prelude = [
  'set -u',
  'store="${JIRA_SEARCH_DIR:-$HOME/.config/omarchy/jira-search}"',
  'cfg="${JIRA_CONFIG_FILE:-$HOME/.config/.jira/.config.yml}"',
  'saved() { [ -r "$store/config" ] && sed -n "s|^$1=||p" "$store/config" | head -n1; }',
  'conf() { [ -r "$cfg" ] && sed -n "s|^$1:[[:space:]]*||p" "$cfg" | head -n1; }',
  'server="${JIRA_SERVER:-}"',
  '[ -n "$server" ] || server=$(saved server)',
  '[ -n "$server" ] || server=$(conf server)',
  'email="${JIRA_EMAIL:-}"',
  '[ -n "$email" ] || email=$(saved email)',
  '[ -n "$email" ] || email=$(conf login)',
  'token="${JIRA_API_TOKEN:-}"',
  'if [ -z "$token" ]; then',
  '  for f in "$store/token" "$HOME/.jira-api-token"; do',
  '    if [ -r "$f" ]; then token=$(head -n1 "$f" | tr -d "\\r\\n"); break; fi',
  '  done',
  'fi',
  'server="${server%/}"',
  '[ -n "$server" ] || exit 10',
  '[ -n "$email" ] || exit 11',
  '[ -n "$token" ] || exit 12',
  'api() {',
  '  printf \'user = "%s:%s"\\nsilent\\nshow-error\\nheader = "Accept: application/json"\\nwrite-out = "\\\\n%%{http_code}"\\n\' "$email" "$token" |',
  '    curl -K - "$server$1" || exit 20',
  '}',
  // Same, but with query parameters curl encodes itself (-G --data-urlencode),
  // so a JQL string with spaces and quotes survives the trip.
  'apiq() {',
  '  path="$1"; shift',
  '  printf \'user = "%s:%s"\\nsilent\\nshow-error\\nheader = "Accept: application/json"\\nwrite-out = "\\\\n%%{http_code}"\\n\' "$email" "$token" |',
  '    curl -K - -G "$@" "$server$path" || exit 20',
  '}'
].join("\n")

// What the settings form should show: the resolved site and account, and
// whether a token is on file. The token itself is never printed.
function configCommand() {
  return ["bash", "-c", prelude.replace(/\n\[ -n "\$server" \] \|\| exit 10[\s\S]*$/, "") + [
    '',
    'esc() { printf \'%s\' "$1" | sed \'s|\\\\|\\\\\\\\|g; s|"|\\\\"|g\'; }',
    'has=false; [ -n "$token" ] && has=true',
    'printf \'{"server":"%s","email":"%s","hasToken":%s}\\n\' "$(esc "$server")" "$(esc "$email")" "$has"'
  ].join("\n")]
}

// Writes what the form collected. Values arrive on stdin, one per line, so the
// token never appears in argv; a blank third line keeps the stored token.
function saveCommand() {
  return ["bash", "-c", [
    'set -u',
    'umask 077',
    'store="${JIRA_SEARCH_DIR:-$HOME/.config/omarchy/jira-search}"',
    'IFS= read -r server || true',
    'IFS= read -r email || true',
    'IFS= read -r token || true',
    'case "$server" in http://*|https://*) ;; *) server="https://$server" ;; esac',
    'server="${server%/}"',
    'mkdir -p "$store" && chmod 700 "$store"',
    'printf \'server=%s\\nemail=%s\\n\' "$server" "$email" > "$store/config"',
    'chmod 600 "$store/config"',
    'if [ -n "$token" ]; then printf \'%s\' "$token" > "$store/token"; chmod 600 "$store/token"; fi',
    '[ -s "$store/token" ] || [ -n "${JIRA_API_TOKEN:-}" ] || exit 12'
  ].join("\n")]
}

// Drops everything this plugin stored. Credentials from the environment or
// from jira-cli's own config are not ours to remove.
function forgetCommand() {
  return ["bash", "-c", [
    'store="${JIRA_SEARCH_DIR:-$HOME/.config/omarchy/jira-search}"',
    'rm -f "$store/config" "$store/token"'
  ].join("\n")]
}

function parseConfig(raw) {
  var data = JSON.parse(String(raw || "").trim())
  return {
    server: text(data.server),
    email: text(data.email),
    hasToken: data.hasToken === true
  }
}

// GET /rest/api/3/myself — the canonical "are these credentials good" call.
function authCommand() {
  return ["bash", "-c", prelude + "\napi /rest/api/3/myself"]
}

function viewCommand(key) {
  return ["bash", "-c", prelude + '\napi "/rest/api/3/issue/$1?fields=' + issueFields + '"', "jira-search", key]
}

// Runs a JQL query as given. GET /rest/api/3/search/jql — the replacement
// for the retired /search.
function searchCommand(jql) {
  return ["bash", "-c",
    prelude + '\napiq /rest/api/3/search/jql --data-urlencode "jql=$1" --data-urlencode "maxResults=' +
      searchLimit + '" --data-urlencode "fields=' + searchFields + '"',
    "jira-search", String(jql)]
}

// JQL string literals take backslash and double quote escapes; everything else
// in the query is left alone so Jira's own text matching decides what it means.
function quoteJql(value) {
  return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}

// A query written as JQL is sent to Jira as-is. The tell has to be something
// nobody types by accident in a free-text search, so it is a field followed by
// a comparison operator ("status = Done", "updated >= -7d", "summary ~ login"),
// one of the shapes that has no operator symbol ("assignee in (…)",
// "fixVersion is empty"), or a bare sort ("ORDER BY created DESC"). Prose like
// "what is broken" has none of those and stays a text search.
var jqlPattern = /(^|[\s(!])[A-Za-z][\w.]*\s*(!?=|!?~|<=?|>=?|\bin\s*\(|\bis\s+(not\s+)?(empty|null)\b)/i
var orderByPattern = /\border\s+by\b/i

function looksLikeJql(query) {
  var q = String(query || "").trim()
  if (q === "") return false
  if (orderByPattern.test(q)) return true
  return jqlPattern.test(q)
}

// --- Filters -----------------------------------------------------------
//
// A search is a stack of filters, each one a thing the user typed and
// submitted, ANDed together. A filter is {kind, value}: "text" runs through
// Jira's own full-text matching, "jql" is a fragment written as JQL and sent
// as written. Whatever is still being typed joins the stack as one more
// filter for as long as it is in the field, so the list narrows as you type
// and the narrowing sticks once you press Enter.

function filterKind(query) {
  return looksLikeJql(query) ? "jql" : "text"
}

function makeFilter(query) {
  var q = String(query || "").trim()
  return { kind: filterKind(q), value: q }
}

// The trailing sort is pulled off a fragment before it is ANDed with the
// others — JQL only takes one ORDER BY, and only at the very end.
function orderByOf(query) {
  var m = String(query || "").match(/\border\s+by\b[\s\S]*$/i)
  return m ? m[0].trim() : ""
}

function stripOrderBy(query) {
  return String(query || "").replace(/\s*\border\s+by\b[\s\S]*$/i, "").trim()
}

// `text ~ "evolving web"` is not the search it looks like. JQL's quotes only
// delimit a string; what is inside goes to Lucene, which splits it into words
// and matches each one separately, with stemming — so that query also returns
// a ticket that says "webinar" in one place and "evolve" in another. A phrase
// needs quotes Lucene can see, which means a second, escaped pair inside the
// JQL ones: text ~ "\"evolving web\"". Those match the words in that order,
// unstemmed.
function phraseJql(value) {
  var lucene = '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  return quoteJql(lucene)
}

// One filter as a JQL fragment. A JQL fragment is parenthesised so that its
// own ORs cannot swallow the filters it is ANDed with.
function filterClause(filter) {
  if (!filter) return ""
  var v = String(filter.value || "").trim()
  if (v === "") return ""
  if (filter.kind === "jql") {
    var body = stripOrderBy(v)
    return body === "" ? "" : "(" + body + ")"
  }
  var clause = 'text ~ ' + phraseJql(v)
  // A key typed as text should still surface the ticket itself.
  if (isValidKey(v)) clause = '(key = ' + quoteJql(normalizeKey(v)) + ' OR ' + clause + ')'
  return clause
}

// The whole search: every committed filter, plus the draft still in the
// field, ANDed. The sort comes from the most recent filter that brought one.
// Returns "" when there is nothing to search on.
function jqlForFilters(filters, draft) {
  var list = (filters || []).slice()
  var d = String(draft || "").trim()
  if (d !== "") list.push(makeFilter(d))

  var parts = []
  var order = ""
  for (var i = 0; i < list.length; i++) {
    if (list[i].kind === "jql") {
      var o = orderByOf(list[i].value)
      if (o !== "") order = o
    }
    var clause = filterClause(list[i])
    if (clause !== "") parts.push(clause)
  }
  if (parts.length === 0) return ""
  return parts.join(" AND ") + " " + (order !== "" ? order : "ORDER BY updated DESC")
}

// What a chip says. A text filter reads as what was typed; a JQL one keeps
// its own words, which already name the field they are about.
function filterLabel(filter) {
  if (!filter) return ""
  return String(filter.value || "")
}

// Adding the same filter twice would narrow nothing, so it is ignored.
function hasFilter(filters, filter) {
  for (var i = 0; i < (filters || []).length; i++) {
    if (filters[i].kind === filter.kind && filters[i].value === filter.value) return true
  }
  return false
}

function parseResults(raw) {
  var data = JSON.parse(raw)
  var issues = data.issues || []
  var out = []
  for (var i = 0; i < issues.length; i++) {
    var f = issues[i].fields || {}
    out.push({
      key: text(issues[i].key),
      // The browse URL is derived from the API URL the issue carries, so a
      // result opens in the browser without a second round trip to fetch it.
      url: issues[i].self
        ? text(issues[i].self).replace(/\/rest\/api\/.*$/, "/browse/" + text(issues[i].key))
        : "",
      summary: text(f.summary),
      status: f.status ? text(f.status.name) : "",
      type: f.issuetype ? text(f.issuetype.name) : "",
      priority: f.priority ? text(f.priority.name) : "",
      assignee: f.assignee ? text(f.assignee.displayName) : "Unassigned",
      updated: text(f.updated)
    })
  }
  return out
}

// A malformed query is the user's to fix, so JQL's own complaint is shown
// rather than a generic failure.
function searchMessage(exitCode, status, body) {
  if (exitCode !== 0 || status === 401 || status === 403) return authMessage(exitCode, status)
  if (status === 200) return ""
  var detail = ""
  try {
    var data = JSON.parse(String(body || ""))
    if (data.errorMessages && data.errorMessages.length) detail = String(data.errorMessages[0])
  } catch (e) {}
  if (status === 400) return detail ? detail.slice(0, 200) : "Jira could not run that search."
  return detail ? detail.slice(0, 200) : "Search failed (HTTP " + status + ")."
}

function normalizeKey(text) {
  return String(text || "").trim().toUpperCase()
}

function isValidKey(text) {
  return keyPattern.test(normalizeKey(text))
}

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// curl appends the HTTP status on its own final line (write-out), so the body
// is everything before it.
function splitResponse(out) {
  var s = String(out || "")
  var i = s.lastIndexOf("\n")
  if (i < 0) return { body: "", status: parseInt(s.trim(), 10) || 0 }
  return { body: s.slice(0, i), status: parseInt(s.slice(i + 1).trim(), 10) || 0 }
}

// Only the handful of fields the panel shows are pulled out, so a field the
// instance doesn't configure comes back empty rather than breaking the parse.
function parseIssue(raw) {
  var data = JSON.parse(raw)
  var f = data.fields || {}
  return {
    key: text(data.key),
    summary: text(f.summary),
    status: f.status ? text(f.status.name) : "",
    type: f.issuetype ? text(f.issuetype.name) : "",
    priority: f.priority ? text(f.priority.name) : "",
    assignee: f.assignee ? text(f.assignee.displayName) : "Unassigned",
    reporter: f.reporter ? text(f.reporter.displayName) : "",
    project: f.project ? text(f.project.name) : "",
    updated: text(f.updated),
    url: data.self ? text(data.self).replace(/\/rest\/api\/.*$/, "/browse/" + text(data.key)) : ""
  }
}

function parseAccount(raw) {
  var data = JSON.parse(raw)
  return text(data.displayName) || text(data.emailAddress) || text(data.accountId)
}

var monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function pad2(n) { return n < 10 ? "0" + n : String(n) }

// A fixed short form — "19 Sep 2026, 00:13". The locale string is unbounded
// (it can spell out the weekday and the timezone name), and the card is not,
// so the timestamp is built rather than borrowed.
function formatUpdated(value) {
  if (!value) return ""
  var d = new Date(value)
  if (isNaN(d.getTime())) return value
  return d.getDate() + " " + monthNames[d.getMonth()] + " " + d.getFullYear()
    + ", " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

var setupHint = "Enter your site, account email and API token below. Create a token at id.atlassian.com/manage-profile/security/api-tokens."

// Credential problems are reported as advice, not as a raw failure: the user
// has to go and fix something outside the plugin.
function authMessage(exitCode, status) {
  if (exitCode === 10) return "No Jira site configured. " + setupHint
  if (exitCode === 11) return "No Jira account configured. " + setupHint
  if (exitCode === 12) return "No API token found. " + setupHint
  if (exitCode === 20) return "Could not reach the Jira site. Check the URL and your connection."
  if (status === 401) return "Jira rejected these credentials (401). Check the account email and API token."
  if (status === 403) return "Jira refused the request (403). The account may need to re-authenticate or lacks permission."
  if (status === 404) return "Jira did not recognise that site address (404). Check the site URL."
  if (status === 429) return "Jira is rate limiting these requests (429). Try again shortly."
  if (exitCode !== 0) return "Authentication check failed (exit " + exitCode + ")."
  if (status !== 200) return "Unexpected response from Jira (HTTP " + status + ")."
  return ""
}

// Lookup errors are per-ticket; anything that smells like credentials is sent
// back through authMessage so the panel can re-gate instead of showing a 401
// next to an empty result.
function lookupMessage(exitCode, status, body) {
  if (exitCode !== 0 || status === 401 || status === 403) return authMessage(exitCode, status)
  if (status === 404) return "No such ticket, or your account can't see it."
  if (status !== 200) {
    var detail = ""
    try {
      var data = JSON.parse(String(body || ""))
      if (data.errorMessages && data.errorMessages.length) detail = String(data.errorMessages[0])
    } catch (e) {}
    return detail ? detail.slice(0, 200) : "Lookup failed (HTTP " + status + ")."
  }
  return ""
}

// A failure the panel should treat as "credentials are no longer good".
function isAuthFailure(exitCode, status) {
  return exitCode === 10 || exitCode === 11 || exitCode === 12 || status === 401 || status === 403
}
