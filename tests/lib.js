// Loads Model.js the way Quickshell does — one shared library scope — and
// runs the commands it builds against the fakes in tests/fakes, in a
// throwaway HOME, so no test reads real credentials or reaches the network.
"use strict"
const fs = require("fs")
const os = require("os")
const path = require("path")
const vm = require("vm")
const { spawnSync } = require("child_process")

const root = path.resolve(__dirname, "..")
const fixtures = path.join(__dirname, "fixtures")
const fakes = path.join(__dirname, "fakes")

function loadModel() {
  const source = fs.readFileSync(path.join(root, "Model.js"), "utf8").replace(/^\.pragma library\n/, "")
  const scope = vm.createContext({})
  vm.runInContext(source, scope, { filename: "Model.js" })
  return scope
}

// A fresh HOME and store per test. Nothing from the caller's environment
// that the prelude reads is passed through.
function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "jira-search-test-"))
  const home = path.join(dir, "home")
  fs.mkdirSync(home)
  const base = {
    PATH: fakes + path.delimiter + process.env.PATH,
    HOME: home,
    LANG: "C",
    FAKE_DIR: dir,
    FAKE_CURL_BODY: path.join(fixtures, "myself.json"),
    JIRA_SEARCH_DIR: path.join(dir, "store"),
    JIRA_CONFIG_FILE: path.join(dir, "no-jira-cli-config.yml")
  }
  return {
    dir: dir,
    store: base.JIRA_SEARCH_DIR,
    run(argv, opts) {
      opts = opts || {}
      const r = spawnSync(argv[0], argv.slice(1), {
        env: Object.assign({}, base, opts.env || {}),
        input: opts.input || "",
        encoding: "utf8"
      })
      if (r.error) throw r.error
      return { code: r.status, stdout: r.stdout, stderr: r.stderr }
    },
    read(name) {
      const p = path.join(dir, name)
      return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : null
    },
    exists(name) { return fs.existsSync(path.join(dir, name)) },
    mode(file) { return fs.statSync(file).mode & 0o777 },
    cleanup() {
      try { fs.chmodSync(base.JIRA_SEARCH_DIR, 0o700) } catch (e) {}
      fs.rmSync(dir, { recursive: true, force: true })
    }
  }
}

module.exports = { loadModel, sandbox, fixtures, root }
