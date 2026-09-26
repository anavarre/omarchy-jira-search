"use strict"
// Runs the bash scripts Model.js builds, with fakes for curl, secret-tool and
// timeout on PATH, and checks what reaches curl and what the panel gets back.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const path = require("path")
const { loadModel, sandbox, fixtures } = require("./lib")

const M = loadModel()
const creds = { JIRA_SERVER: "https://acme.example.test", JIRA_EMAIL: "dev@example.test", JIRA_API_TOKEN: "fictional-token-123" }

function withSandbox(fn) {
  return () => {
    const box = sandbox()
    try { fn(box) } finally { box.cleanup() }
  }
}

function save(box, lines, env) {
  return box.run(M.saveCommand(), { input: lines.join("\n") + "\n", env: env })
}

test("auth sends the token through curl's stdin config, never argv", withSandbox(box => {
  const r = box.run(M.authCommand(), { env: creds })
  assert.equal(r.code, 0, r.stderr)
  const res = M.splitResponse(r.stdout)
  assert.equal(res.site, creds.JIRA_SERVER)
  assert.equal(res.status, 200)
  assert.equal(M.parseAccount(res.body), "Dana Example")
  assert.match(box.read("curl.cfg"), /^user = "dev@example\.test:fictional-token-123"$/m)
  assert.match(box.read("curl.cfg"), /^proto = "=https"$/m)
  const argv = box.read("curl.argv").split("\n")
  assert.equal(argv[0], "-q")
  assert.ok(argv.includes(creds.JIRA_SERVER + "/rest/api/3/myself"))
  assert.doesNotMatch(box.read("curl.argv"), /fictional-token/)
}))

test("a bare host gets https and loses its trailing slash", withSandbox(box => {
  const r = box.run(M.authCommand(), { env: Object.assign({}, creds, { JIRA_SERVER: "acme.example.test/" }) })
  assert.equal(M.splitResponse(r.stdout).site, "https://acme.example.test")
}))

test("a plaintext site is refused before curl runs", withSandbox(box => {
  const r = box.run(M.authCommand(), { env: Object.assign({}, creds, { JIRA_SERVER: "http://acme.example.test" }) })
  assert.equal(r.code, 13)
  assert.equal(box.exists("curl.cfg"), false)
}))

test("missing site, account or token exit 10, 11 and 12", withSandbox(box => {
  assert.equal(box.run(M.authCommand(), { env: { JIRA_EMAIL: "a", JIRA_API_TOKEN: "b" } }).code, 10)
  assert.equal(box.run(M.authCommand(), { env: { JIRA_SERVER: "x.example.test", JIRA_API_TOKEN: "b" } }).code, 11)
  assert.equal(box.run(M.authCommand(), { env: { JIRA_SERVER: "x.example.test", JIRA_EMAIL: "a" } }).code, 12)
  assert.equal(box.exists("curl.cfg"), false)
}))

test("quotes, backslashes and newlines cannot break out of the curl config", withSandbox(box => {
  const env = Object.assign({}, creds, { JIRA_EMAIL: 'dev"x\\y@example.test', JIRA_API_TOKEN: 'tok\nurl = "https://evil.example.test"' })
  assert.equal(box.run(M.authCommand(), { env: env }).code, 0)
  const cfg = box.read("curl.cfg")
  assert.match(cfg, /^user = "dev\\"x\\\\y@example\.test:tokurl = \\"https:\/\/evil\.example\.test\\""$/m)
  assert.doesNotMatch(cfg, /^url/m)
}))

test("a 401 comes back as a status the panel re-gates on", withSandbox(box => {
  const r = box.run(M.authCommand(), { env: Object.assign({ FAKE_CURL_BODY: path.join(fixtures, "unauthorized.json"), FAKE_CURL_STATUS: "401" }, creds) })
  assert.equal(r.code, 0)
  const res = M.splitResponse(r.stdout)
  assert.equal(res.status, 401)
  assert.equal(M.isAuthFailure(r.code, res.status), true)
  assert.match(M.authMessage(r.code, res.status), /401/)
}))

test("curl failures map to their exit codes", withSandbox(box => {
  const cases = { timeout: 21, refused: 22, oversize: 22, offline: 20 }
  for (const mode of Object.keys(cases)) {
    const r = box.run(M.authCommand(), { env: Object.assign({ FAKE_CURL: mode }, creds) })
    assert.equal(r.code, cases[mode], mode)
  }
}))

test("malformed JSON reaches the parser, which rejects it", withSandbox(box => {
  const r = box.run(M.viewCommand("ABC-42"), { env: Object.assign({ FAKE_CURL_BODY: path.join(fixtures, "malformed.html") }, creds) })
  assert.equal(r.code, 0)
  const res = M.splitResponse(r.stdout)
  assert.equal(res.status, 200)
  assert.throws(() => M.parseIssue(res.body, res.site), { name: "SyntaxError" })
}))

test("an issue lookup parses end to end", withSandbox(box => {
  const r = box.run(M.viewCommand("ABC-42"), { env: Object.assign({ FAKE_CURL_BODY: path.join(fixtures, "issue.json") }, creds) })
  const res = M.splitResponse(r.stdout)
  const issue = M.parseIssue(res.body, res.site)
  assert.equal(issue.summary, "Fictional login page times out")
  assert.equal(issue.url, "https://acme.example.test/browse/ABC-42")
}))

test("a key or query is passed as data, never run as shell", withSandbox(box => {
  const hostile = 'ABC-1$(touch "$FAKE_DIR/pwned")`touch "$FAKE_DIR/pwned2"`;touch "$FAKE_DIR/pwned3"'
  box.run(M.viewCommand(hostile), { env: creds })
  assert.ok(box.read("curl.argv").includes("/rest/api/3/issue/" + hostile + "?fields="))
  box.run(M.searchCommand(hostile), { env: creds })
  assert.ok(box.read("curl.argv").split("\n").includes("jql=" + hostile))
  for (const f of ["pwned", "pwned2", "pwned3"]) assert.equal(box.exists(f), false, f)
}))

test("a search sends its JQL, limit and fields url-encoded by curl", withSandbox(box => {
  const jql = M.jqlForFilters([M.makeFilter("open web")], "project = WEB")
  const r = box.run(M.searchCommand(jql), { env: Object.assign({ FAKE_CURL_BODY: path.join(fixtures, "search.json") }, creds) })
  const argv = box.read("curl.argv").split("\n")
  assert.ok(argv.includes("-G"))
  assert.ok(argv.includes("jql=" + jql))
  assert.ok(argv.includes("maxResults=" + M.searchLimit))
  assert.ok(argv.includes("https://acme.example.test/rest/api/3/search/jql"))
  const res = M.splitResponse(r.stdout)
  assert.equal(M.parseResults(res.body, res.site).length, 3)
}))

test("saving puts the token in the keyring and nothing on disk", withSandbox(box => {
  assert.equal(save(box, ["acme.example.test/", "dev@example.test", "fictional-token-123"]).code, 0)
  assert.equal(fs.readFileSync(path.join(box.store, "config"), "utf8"), "server=https://acme.example.test\nemail=dev@example.test\n")
  assert.equal(box.mode(path.join(box.store, "config")), 0o600)
  assert.equal(box.mode(box.store), 0o700)
  assert.equal(fs.existsSync(path.join(box.store, "token")), false)
  assert.equal(box.read("keyring"), "fictional-token-123")
  assert.match(box.read("keyring.log"), /^store --label=Jira Search API token service anavarre\.jira-search kind api-token$/m)

  const cfg = M.parseConfig(box.run(M.configCommand()).stdout)
  assert.deepEqual(JSON.parse(JSON.stringify(cfg)), { server: "https://acme.example.test", email: "dev@example.test", hasToken: true })
  assert.equal(box.run(M.authCommand()).code, 0)
  assert.match(box.read("curl.cfg"), /^user = "dev@example\.test:fictional-token-123"$/m)
}))

test("a blank token field keeps the stored token", withSandbox(box => {
  save(box, ["acme.example.test", "dev@example.test", "fictional-token-123"])
  assert.equal(save(box, ["acme.example.test", "other@example.test", ""]).code, 0)
  assert.equal(box.read("keyring"), "fictional-token-123")
  assert.equal(M.parseConfig(box.run(M.configCommand()).stdout).email, "other@example.test")
}))

test("saving without any token fails with 12", withSandbox(box => {
  assert.equal(save(box, ["acme.example.test", "dev@example.test", ""]).code, 12)
}))

test("without a keyring the token goes to a 0600 file", withSandbox(box => {
  const down = { FAKE_KEYRING_DOWN: "1" }
  assert.equal(save(box, ["acme.example.test", "dev@example.test", "fictional-token-123"], down).code, 0)
  const token = path.join(box.store, "token")
  assert.equal(fs.readFileSync(token, "utf8"), "fictional-token-123")
  assert.equal(box.mode(token), 0o600)
  assert.equal(M.parseConfig(box.run(M.configCommand(), { env: down }).stdout).hasToken, true)
}))

test("a keyring save removes an older token file", withSandbox(box => {
  save(box, ["acme.example.test", "dev@example.test", "old-token"], { FAKE_KEYRING_DOWN: "1" })
  save(box, ["acme.example.test", "dev@example.test", "new-token"])
  assert.equal(fs.existsSync(path.join(box.store, "token")), false)
  assert.equal(box.read("keyring"), "new-token")
}))

test("the environment token wins over the keyring", withSandbox(box => {
  save(box, ["acme.example.test", "dev@example.test", "keyring-token"])
  box.run(M.authCommand(), { env: { JIRA_API_TOKEN: "env-token" } })
  assert.match(box.read("curl.cfg"), /:env-token"$/m)
}))

test("an unwritable store fails with 14", withSandbox(box => {
  if (process.getuid && process.getuid() === 0) return
  fs.mkdirSync(box.store)
  fs.writeFileSync(path.join(box.store, "config"), "")
  fs.chmodSync(path.join(box.store, "config"), 0o400)
  fs.chmodSync(box.store, 0o500)
  assert.equal(save(box, ["acme.example.test", "dev@example.test", "fictional-token-123"]).code, 14)
}))

test("forget removes the files and the keyring entry", withSandbox(box => {
  save(box, ["acme.example.test", "dev@example.test", "fictional-token-123"])
  fs.writeFileSync(path.join(box.store, "token"), "stray")
  assert.equal(box.run(M.forgetCommand()).code, 0)
  assert.deepEqual(fs.readdirSync(box.store), [])
  assert.equal(box.exists("keyring"), false)
  assert.equal(M.parseConfig(box.run(M.configCommand()).stdout).hasToken, false)
}))

test("forget fails with 14 when the keyring entry stays, but still clears the files", withSandbox(box => {
  save(box, ["acme.example.test", "dev@example.test", "fictional-token-123"])
  assert.equal(box.run(M.forgetCommand(), { env: { FAKE_KEYRING_STUCK: "1" } }).code, 14)
  assert.deepEqual(fs.readdirSync(box.store), [])
}))
