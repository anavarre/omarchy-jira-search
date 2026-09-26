"use strict"
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const path = require("path")
const { loadModel, fixtures } = require("./lib")

const M = loadModel()
const site = "https://acme.example.test"
const fixture = name => fs.readFileSync(path.join(fixtures, name), "utf8")
// Values built inside the Model.js context carry that context's prototypes,
// which deepStrictEqual would count as a difference.
const plain = value => JSON.parse(JSON.stringify(value))

test("keys are recognised in any case, and nothing else is", () => {
  assert.equal(M.isValidKey("abc-123"), true)
  assert.equal(M.isValidKey(" ABC_2-9 "), true)
  assert.equal(M.normalizeKey(" abc-1 "), "ABC-1")
  for (const bad of ["", "ABC", "ABC-", "1BC-2", "A-1", "ABC-1x", "ABC 1"]) {
    assert.equal(M.isValidKey(bad), false, bad)
  }
})

test("JQL is told apart from prose", () => {
  for (const jql of ["status = Done", "updated >= -7d", "summary ~ login", "assignee in (currentUser())",
                     "sprint IN openSprints()", "fixVersion is empty", "ORDER BY created DESC", "(labels != x)"]) {
    assert.equal(M.looksLikeJql(jql), true, jql)
  }
  for (const prose of ["", "   ", "what is broken", "login error", "open web", "in progress"]) {
    assert.equal(M.looksLikeJql(prose), false, prose)
  }
})

test("every JQL example is detected as JQL", () => {
  for (const example of M.jqlExamples) assert.equal(M.looksLikeJql(example.jql), true, example.jql)
})

test("text filters become exact-phrase matches and escape quotes", () => {
  assert.equal(M.jqlForFilters([], "open web"), 'text ~ "\\"open web\\"" AND statusCategory != Done ORDER BY updated DESC')
  assert.equal(M.filterClause(M.makeFilter('say "hi"')), 'text ~ "\\"say \\\\\\"hi\\\\\\"\\""')
  assert.equal(M.quoteJql('a\\b"c'), '"a\\\\b\\"c"')
})

test("a key typed as text also matches the ticket itself", () => {
  assert.equal(M.filterClause(M.makeFilter("abc-7")), '(key = "ABC-7" OR text ~ "\\"abc-7\\"")')
})

test("filters are ANDed, JQL is parenthesised, and the last sort wins", () => {
  const filters = [M.makeFilter("open web"), M.makeFilter("project = WEB OR project = APP ORDER BY created ASC")]
  assert.equal(M.jqlForFilters(filters, "priority = High ORDER BY rank"),
    'text ~ "\\"open web\\"" AND (project = WEB OR project = APP) AND (priority = High) AND statusCategory != Done ORDER BY rank')
})

test("finished work is only included when a filter talks about status", () => {
  assert.match(M.jqlForFilters([M.makeFilter("login")], ""), /statusCategory != Done/)
  assert.doesNotMatch(M.jqlForFilters([M.makeFilter("status = Done")], ""), /statusCategory != Done/)
  assert.doesNotMatch(M.jqlForFilters([M.makeFilter("resolved >= -7d")], ""), /statusCategory != Done/)
})

test("nothing to search on gives an empty query", () => {
  assert.equal(M.jqlForFilters([], "  "), "")
  assert.equal(M.jqlForFilters([M.makeFilter("ORDER BY created DESC")], ""), "")
})

test("duplicate filters are spotted", () => {
  const filters = [M.makeFilter("login")]
  assert.equal(M.hasFilter(filters, M.makeFilter(" login ")), true)
  assert.equal(M.hasFilter(filters, M.makeFilter("logout")), false)
})

test("the summon payload is read defensively", () => {
  assert.deepEqual(plain(M.parsePayload('{"query":"project = ABC"}')), { query: "project = ABC" })
  assert.deepEqual(plain(M.parsePayload({ query: "direct" })), { query: "direct" })
  for (const junk of ["", "not json", "[1,2]", "null", "42", '{"query":7}', null, undefined]) {
    assert.deepEqual(plain(M.parsePayload(junk)), { query: "" }, String(junk))
  }
  assert.equal(M.parsePayload({ query: "a\nb c\td" }).query, "a b c d")
  assert.equal(M.parsePayload({ query: "x".repeat(2000) }).query.length, M.maxPrefill)
})

test("responses split into site, body and status", () => {
  assert.deepEqual(plain(M.splitResponse(site + '\n{"a":1}\n{"b":2}\n200')),
    { site: site, body: '{"a":1}\n{"b":2}', status: 200 })
  assert.deepEqual(plain(M.splitResponse(site + "\n401")), { site: site, body: "", status: 401 })
  assert.equal(M.splitResponse("").status, 0)
})

test("only https sites on a plain host are accepted", () => {
  for (const good of [site, "https://jira.example.test:8443", "https://example.test/jira"]) {
    assert.equal(M.isValidSite(good), true, good)
  }
  for (const bad of ["", "http://acme.example.test", "https://user@acme.example.test", "https://acme.example.test/?x=1",
                     "https://acme.example.test#frag", "javascript:alert(1)", "https://acme.example.test/"]) {
    assert.equal(M.isValidSite(bad), false, bad)
  }
})

test("browse links are built from the configured site, never the response", () => {
  assert.equal(M.browseUrl(site, "ABC-42"), site + "/browse/ABC-42")
  assert.equal(M.browseUrl(site, "javascript:alert(1)"), "")
  assert.equal(M.browseUrl("http://acme.example.test", "ABC-42"), "")
  assert.equal(M.isSafeBrowseUrl(site + "/browse/ABC-42", site), true)
  assert.equal(M.isSafeBrowseUrl("https://elsewhere.example.test/browse/ABC-42", site), false)
  assert.equal(M.isSafeBrowseUrl(site + "/browse/ABC-42/../../x", site), false)
})

test("search results parse, with a bad key left without a link", () => {
  const results = M.parseResults(fixture("search.json"), site)
  assert.equal(results.length, 3)
  assert.deepEqual(plain(results[0]), {
    key: "ABC-42", url: site + "/browse/ABC-42", summary: "Fictional login page times out",
    status: "In Progress", type: "Bug", priority: "High", assignee: "Dana Example",
    updated: "2026-09-19T00:13:00.000+0000"
  })
  assert.equal(results[1].assignee, "Unassigned")
  assert.equal(results[1].status, "")
  assert.equal(results[2].url, "")
})

test("an issue parses, and its link ignores the self URL", () => {
  const issue = M.parseIssue(fixture("issue.json"), site)
  assert.equal(issue.key, "ABC-42")
  assert.equal(issue.reporter, "Sam Sample")
  assert.equal(issue.project, "Alpha Project")
  assert.equal(issue.url, site + "/browse/ABC-42")
})

test("the account shows the best name available", () => {
  assert.equal(M.parseAccount(fixture("myself.json")), "Dana Example")
  assert.equal(M.parseAccount('{"emailAddress":"dev@example.test"}'), "dev@example.test")
})

test("malformed JSON throws, for the panel to catch", () => {
  const html = fixture("malformed.html")
  assert.throws(() => M.parseResults(html, site), { name: "SyntaxError" })
  assert.throws(() => M.parseIssue(html, site), { name: "SyntaxError" })
  assert.throws(() => M.parseAccount(html), { name: "SyntaxError" })
  assert.throws(() => M.parseConfig(html), { name: "SyntaxError" })
})

test("the settings summary never claims a token it was not told about", () => {
  assert.deepEqual(plain(M.parseConfig('{"server":"' + site + '","email":"dev@example.test","hasToken":true}')),
    { server: site, email: "dev@example.test", hasToken: true })
  assert.equal(M.parseConfig('{"hasToken":"true"}').hasToken, false)
})

test("timestamps get a short fixed form", () => {
  assert.equal(M.formatUpdated("2026-09-19T00:13:00.000+0000"), "19 Sep 2026, 00:13")
  assert.equal(M.formatUpdated(""), "")
  assert.equal(M.formatUpdated("soon"), "soon")
})

test("every exit code has its own message", () => {
  const seen = new Set()
  for (const code of [10, 11, 12, 13, 14, 20, 21, 22]) {
    const message = M.authMessage(code, 0)
    assert.ok(message, "exit " + code)
    seen.add(message)
  }
  assert.equal(seen.size, 8)
  assert.match(M.authMessage(21, 0), new RegExp("over " + M.maxTime + "s"))
  assert.match(M.authMessage(22, 0), /over 1 MB/)
  assert.equal(M.authMessage(0, 200), "")
})

test("401 and 403 are credential failures, other errors are not", () => {
  assert.match(M.authMessage(0, 401), /rejected these credentials/)
  assert.equal(M.isAuthFailure(0, 401), true)
  assert.equal(M.isAuthFailure(0, 403), true)
  assert.equal(M.isAuthFailure(12, 0), true)
  assert.equal(M.isAuthFailure(21, 0), false)
  assert.equal(M.isAuthFailure(0, 404), false)
  assert.equal(M.searchMessage(0, 401, fixture("unauthorized.json")), M.authMessage(0, 401))
})

test("Jira's own complaint about a query is shown, and junk falls back", () => {
  assert.equal(M.searchMessage(0, 400, fixture("bad-jql.json")),
    "Field 'colour' does not exist or you do not have permission to view it.")
  assert.equal(M.searchMessage(0, 400, fixture("malformed.html")), "Jira could not run that search.")
  assert.equal(M.searchMessage(0, 503, fixture("malformed.html")), "Search failed (HTTP 503).")
  assert.equal(M.searchMessage(0, 200, ""), "")
  assert.equal(M.lookupMessage(0, 404, ""), "No such ticket, or your account can't see it.")
  assert.equal(M.lookupMessage(0, 500, fixture("malformed.html")), "Lookup failed (HTTP 500).")
  assert.equal(M.searchMessage(0, 400, JSON.stringify({ errorMessages: ["x".repeat(500)] })).length, 200)
})
