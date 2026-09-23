import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.jira-search"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  property bool loading: false
  property string errorText: ""
  property var issue: null

  // The field does two jobs. Anything typed searches as you go and lists up to
  // 20 matches; Enter pins what was typed as a filter so the next thing typed
  // narrows it further. A complete ticket ID submitted with Enter on its own,
  // with nothing pinned, skips the list and fetches the ticket's full
  // metadata — typed but not submitted it stays a search that happens to
  // match one ticket.
  property bool searching: false
  property var results: []
  property string resultsQuery: ""
  property int selected: -1

  // Submitted searches stack up as filters instead of replacing one another:
  // "evolving web", then "project = HAAS", is every HAAS ticket mentioning
  // evolving web. Each one is a chip above the field and can be taken back
  // out on its own; the JQL actually sent is all of them ANDed together,
  // along with whatever is still being typed.
  property var filters: []

  // A query Jira itself would read as JQL ("status = Done", "assignee in (…)")
  // is run verbatim. Half-written JQL is a syntax error, and a syntax error per
  // keystroke is noise, so JQL waits for Enter instead of searching as you type.
  property bool isJql: false
  readonly property bool showResults: root.issue === null && root.results.length > 0

  // The draft only joins the search once it is long enough to mean something;
  // short of that the committed filters search on their own. JQL still waits
  // for Enter, since half-written JQL is a syntax error per keystroke.
  readonly property string draftQuery: {
    var d = field.text.trim()
    if (root.isJql || d.length < root.minQuery) return ""
    return d
  }
  readonly property string pendingJql: Model.jqlForFilters(root.filters, root.draftQuery)

  // One or two characters match most of the instance, so a search that short
  // costs a round trip to say nothing useful. Nothing is sent until three.
  readonly property int minQuery: 3

  // "unknown" until the first check, then "checking" / "ok" / "error".
  // Lookups are gated on "ok" so a credential problem is reported once, as
  // setup advice, instead of once per ticket as an opaque 401.
  property string authState: "unknown"
  property string authError: ""
  property string authAccount: ""
  readonly property bool authenticated: authState === "ok"

  // The settings form. It opens by itself whenever credentials don't work,
  // and on demand from "Change credentials".
  property bool configuring: false
  property bool saving: false
  property bool hasStoredToken: false
  readonly property bool showSettings: root.configuring || root.authState === "error"

  // The card floats in the middle of the screen rather than hanging off the
  // bar, so it can no longer size itself to its contents: a centered surface
  // that grows and shrinks under the cursor jumps around as you type. It is
  // a fixed square instead — as tall as it is wide, at 1.3x the 720 the bar
  // popout was wide — and the screen only ever shrinks it on a small output.
  readonly property real cardScale: 1.3
  readonly property real cardSize: Math.round(Style.space(720) * root.cardScale)
  readonly property real cardWidth: panel.fittedContentWidth(root.cardSize)
  readonly property real cardHeight: panel.cappedContentHeight(root.cardSize)

  // What the square leaves the results list once the card's own padding and
  // the chrome sitting above and below the list are taken out.
  readonly property real resultsChrome: Style.space(96)
  readonly property real maxResultsHeight: Math.max(Style.space(120),
    root.cardHeight - panel.verticalContentInset - root.resultsChrome)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  // Type scale, borrowed from the obsidian-focused-search plugin next door:
  // the menu family rather than the bar's font, and a step up from the sizes
  // the bar popout used. A window in the middle of the screen is read, not
  // glanced at on the way past, so the bar's compact type is too small here.
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int fontHeading: Style.fontPx(1.5)
  readonly property int fontBody: Style.font.heading
  readonly property int fontMeta: Style.font.title

  function open() { root.controller.show() }
  function close() { root.controller.hide() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // Fills the form with whatever is already resolved (site and account only —
  // the token is never read back out of storage).
  function loadConfig() {
    configProcess.command = Model.configCommand()
    configProcess.running = true
  }

  function openSettings() {
    root.configuring = true
    root.loadConfig()
    Qt.callLater(function() { siteField.forceActiveFocus() })
  }

  function saveSettings() {
    if (siteField.text.trim() === "" || emailField.text.trim() === "") {
      root.authState = "error"
      root.authError = "Site address and account email are both required."
      return
    }
    root.saving = true
    root.authError = ""
    saveProcess.payload = siteField.text.trim() + "\n" + emailField.text.trim() + "\n" + tokenField.text + "\n"
    saveProcess.command = Model.saveCommand()
    saveProcess.running = true
  }

  function cancelSettings() {
    if (!root.authenticated) { root.close(); return }
    root.configuring = false
    tokenField.text = ""
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function forgetSettings() {
    forgetProcess.command = Model.forgetCommand()
    forgetProcess.running = true
  }

  function checkAuth() {
    if (root.authState === "checking") return
    root.authState = "checking"
    root.authError = ""
    authProcess.command = Model.authCommand()
    authProcess.running = true
  }

  // Enter. A card on screen is a ticket already resolved, and opening it is
  // what the card is for, so Enter opens it. A highlighted result opens; a
  // complete ticket ID typed on its own resolves to the ticket itself;
  // anything else becomes a filter, the field empties, and the search re-runs
  // with one more condition on it.
  function submit(text) {
    if (!root.authenticated) { root.checkAuth(); return }
    // A query still settling is a different ticket in the making, and the card
    // under it is already stale — that falls through to the search below.
    if (root.issue !== null && root.issue.url !== "" && !debounce.running) {
      root.openIssue()
      return
    }
    debounce.stop()
    var trimmed = String(text).trim()
    if (root.selected >= 0 && root.selected < root.results.length) {
      root.openResult(root.selected)
      return
    }
    if (trimmed === "") {
      // Enter on an empty field still runs whatever the chips already say.
      if (root.filters.length > 0) root.runSearch()
      else root.clearResults()
      return
    }
    if (root.filters.length === 0 && Model.isValidKey(trimmed) && !Model.looksLikeJql(trimmed)) {
      field.text = Model.normalizeKey(trimmed)
      root.lookup(trimmed)
      return
    }
    root.addFilter(trimmed)
  }

  // A query settled without Enter is still just a draft: it narrows the list
  // but is not committed. A complete ticket ID typed on its own is the one
  // thing that resolves by itself, the same way Enter would resolve it.
  function dispatch() {
    if (root.filters.length === 0) {
      var trimmed = field.text.trim()
      if (trimmed.length < root.minQuery) { root.clearResults(); return }
      if (Model.isValidKey(trimmed) && !Model.looksLikeJql(trimmed)) {
        root.clearResults()
        root.lookup(trimmed)
        return
      }
    }
    root.runSearch()
  }

  function addFilter(text) {
    var filter = Model.makeFilter(text)
    if (filter.value === "") return
    if (!Model.hasFilter(root.filters, filter)) root.filters = root.filters.concat([filter])
    field.text = ""
    root.isJql = false
    root.selected = -1
    root.runSearch()
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function removeFilter(index) {
    if (index < 0 || index >= root.filters.length) return
    var next = root.filters.slice()
    next.splice(index, 1)
    root.filters = next
    root.selected = -1
    root.issue = null
    if (root.pendingJql === "") root.clearResults()
    else root.runSearch()
  }

  function clearFilters() {
    root.filters = []
    root.selected = -1
    root.issue = null
    if (root.pendingJql === "") root.clearResults()
    else root.runSearch()
  }

  // A result is a ticket you already picked, so it goes straight to the
  // browser rather than through the metadata card — the card is for a ticket
  // ID typed blind, where seeing what it is before leaving is the point. The
  // browse URL rides along on the result, so there is nothing to fetch first.
  function openResult(index) {
    if (index < 0 || index >= root.results.length) return
    var result = root.results[index]
    if (result.url === "") { root.lookup(result.key); return }
    Qt.openUrlExternally(result.url)
    root.close()
  }

  function openIssue() {
    if (root.issue === null || root.issue.url === "") return
    Qt.openUrlExternally(root.issue.url)
    root.close()
  }

  // Full metadata for one ticket. An in-flight lookup is left to finish and its
  // result discarded — `issue` is only written by the run that is still wanted.
  function lookup(text) {
    if (!root.authenticated) { root.checkAuth(); return }
    var key = Model.normalizeKey(text)
    if (!Model.isValidKey(key)) return
    root.issue = null
    root.errorText = ""
    root.loading = true
    viewProcess.command = Model.viewCommand(key)
    viewProcess.running = true
  }

  // Every filter plus the draft, as one JQL query.
  function runSearch() {
    if (!root.authenticated) { root.checkAuth(); return }
    debounce.stop()
    var jql = root.pendingJql
    if (jql === "") { root.clearResults(); return }
    root.issue = null
    root.errorText = ""
    root.searching = true
    searchProcess.query = jql
    searchProcess.command = Model.searchCommand(jql)
    searchProcess.running = true
  }

  // Only the results go; the filters are the user's and stay until they say
  // otherwise.
  function clearResults() {
    root.results = []
    root.resultsQuery = ""
    root.selected = -1
    root.errorText = ""
    root.searching = false
    debounce.stop()
  }

  // Back out of a ticket to the list it came from, if there is one.
  function back() {
    if (root.issue !== null && root.results.length > 0) { root.issue = null; return }
    if (field.text !== "") { field.text = ""; return }
    if (root.filters.length > 0) { root.clearFilters(); return }
    root.close()
  }

  // The buttons the current view is showing, in the order they are laid out.
  // Arrow keys walk this list without taking real focus away from the text
  // field, so a ticket can be opened without ever reaching for the mouse.
  readonly property var actions: {
    if (root.showSettings) {
      var form = ["save"]
      if (root.authenticated) form.push("cancel")
      if (root.hasStoredToken) form.push("forget")
      return form
    }
    if (!root.authenticated || root.loading) return []
    if (root.issue !== null) {
      var view = []
      if (root.results.length > 0) view.push("back")
      return view
    }
    var list = []
    if (root.filters.length > 1) list.push("clear")
    if (!root.searching && root.errorText === "" && root.results.length === 0
        && root.filters.length === 0) list.push("credentials")
    return list
  }
  property int action: -1

  // Whatever changed the button list also changed the view under it, so the
  // cursor starts over rather than pointing at a button that moved.
  onActionsChanged: root.action = -1

  function isAction(id) {
    return root.action >= 0 && root.action < root.actions.length && root.actions[root.action] === id
  }

  function moveAction(delta) {
    if (root.actions.length === 0) return false
    var next = root.action < 0 ? 0 : root.action + delta
    if (next < 0) { root.action = -1; return true }
    if (next >= root.actions.length) next = root.actions.length - 1
    root.action = next
    return true
  }

  function activateAction() {
    if (root.action < 0 || root.action >= root.actions.length) return false
    var id = root.actions[root.action]
    root.action = -1
    if (id === "save") root.saveSettings()
    else if (id === "cancel") root.cancelSettings()
    else if (id === "forget") root.forgetSettings()
    else if (id === "credentials") root.openSettings()
    else if (id === "clear") root.clearFilters()
    else if (id === "back") root.issue = null
    return true
  }

  // Shared by every field in the panel: Down enters the button row (after the
  // results list, where there is one), Left/Right walk it, Up backs out of it,
  // Enter presses the button the cursor is on. Anything the cursor isn't
  // involved in is left to the field itself.
  function handleNavKey(event, withResults) {
    if (event.key === Qt.Key_Escape && root.action >= 0) { root.action = -1; return true }
    if (event.key === Qt.Key_Down) {
      if (withResults && root.action < 0 && root.showResults && root.selected < root.results.length - 1) {
        root.moveSelection(1)
        return true
      }
      return root.moveAction(1)
    }
    if (event.key === Qt.Key_Up) {
      if (root.action >= 0) { root.action = root.action === 0 ? -1 : root.action - 1; return true }
      if (withResults && root.showResults) { root.moveSelection(-1); return true }
      return false
    }
    if (event.key === Qt.Key_Right) return root.action >= 0 && root.moveAction(1)
    if (event.key === Qt.Key_Left) return root.action >= 0 && root.moveAction(-1)
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) return root.activateAction()
    return false
  }

  // With nothing typed, a lone result is unambiguous: put the cursor on it so
  // Enter opens it without an extra Down first.
  function resetSelection() {
    root.selected = (field.text.trim() === "" && root.issue === null
      && root.results.length === 1) ? 0 : -1
  }

  function moveSelection(delta) {
    if (!root.showResults) return
    var next = root.selected + delta
    if (next < 0) next = -1
    if (next >= root.results.length) next = root.results.length - 1
    root.selected = next
    resultsView.revealSelected()
  }

  // Typing resolves, but only once it stops: one request per pause, not one
  // per keystroke.
  Timer {
    id: debounce
    interval: 300
    onTriggered: root.dispatch()
  }

  // Each open starts clean and with the cursor in the field, so the panel is
  // ready to type into whether it was summoned by click or by shell command.
  onOpenedChanged: {
    if (opened) {
      if (root.authState === "unknown" || root.authState === "error") root.checkAuth()
      if (root.showSettings) root.loadConfig()
      field.selectAll()
      Qt.callLater(function() {
        if (root.showSettings) siteField.forceActiveFocus()
        else field.forceActiveFocus()
      })
    }
  }

  Process {
    id: configProcess
    running: false
    command: []
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var cfg = Model.parseConfig(configStdout.text)
        root.hasStoredToken = cfg.hasToken
        if (siteField.text === "") siteField.text = cfg.server
        if (emailField.text === "") emailField.text = cfg.email
      } catch (e) {}
    }
  }

  // The token reaches the script over stdin, so it stays out of argv.
  Process {
    id: saveProcess
    property string payload: ""
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.authState = "error"
        root.authError = Model.authMessage(exitCode, 0)
        return
      }
      tokenField.text = ""
      root.configuring = false
      root.checkAuth()
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    onExited: function() {
      siteField.text = ""
      emailField.text = ""
      tokenField.text = ""
      root.hasStoredToken = false
      root.authAccount = ""
      root.issue = null
      root.errorText = ""
      root.configuring = true
      root.checkAuth()
    }
  }

  // GET /rest/api/3/myself with Basic auth — 200 means the credentials the
  // lookup will use are actually good.
  Process {
    id: authProcess
    running: false
    command: []
    stdout: StdioCollector { id: authStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var res = Model.splitResponse(authStdout.text)
      var message = Model.authMessage(exitCode, res.status)
      if (message !== "") {
        root.authState = "error"
        root.authError = message
        root.authAccount = ""
        root.loadConfig()
        return
      }
      try {
        root.authAccount = Model.parseAccount(res.body)
      } catch (e) {
        root.authAccount = ""
      }
      root.authState = "ok"
      root.authError = ""
      root.configuring = false
      Qt.callLater(function() { field.forceActiveFocus() })
    }
  }

  Process {
    id: viewProcess
    running: false
    command: []
    stdout: StdioCollector { id: viewStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var res = Model.splitResponse(viewStdout.text)
      var message = Model.lookupMessage(exitCode, res.status, res.body)
      if (message !== "") {
        root.issue = null
        // Credentials that stopped working re-gate the panel rather than
        // leaving a dead field behind.
        if (Model.isAuthFailure(exitCode, res.status)) {
          root.authState = "error"
          root.authError = message
          root.errorText = ""
        } else {
          root.errorText = message
        }
        return
      }
      try {
        root.issue = Model.parseIssue(res.body)
        root.errorText = ""
      } catch (e) {
        root.issue = null
        root.errorText = "Could not read the Jira response."
      }
    }
  }

  // Only the newest query is allowed to paint: a slow earlier request that
  // lands after the user has typed on is dropped.
  Process {
    id: searchProcess
    property string query: ""
    running: false
    command: []
    stdout: StdioCollector { id: searchStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // A slower earlier query that lands after the filters or the draft
      // moved on is no longer the search anybody asked for.
      if (searchProcess.query !== root.pendingJql) return
      root.searching = false
      var res = Model.splitResponse(searchStdout.text)
      var message = Model.searchMessage(exitCode, res.status, res.body)
      if (message !== "") {
        root.results = []
        root.selected = -1
        if (Model.isAuthFailure(exitCode, res.status)) {
          root.authState = "error"
          root.authError = message
          root.errorText = ""
        } else {
          root.errorText = message
        }
        return
      }
      try {
        root.results = Model.parseResults(res.body)
        root.resultsQuery = searchProcess.query
        root.resetSelection()
        root.errorText = root.results.length === 0
          ? (root.filters.length > 0 && root.draftQuery === ""
              ? "No tickets match these filters."
              : "No tickets match \u201c" + (root.draftQuery !== "" ? root.draftQuery : field.text.trim()) + "\u201d.")
          : ""
      } catch (e) {
        root.results = []
        root.errorText = "Could not read the Jira response."
      }
    }
  }

  CenteredPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.showSettings ? siteField : field
    contentWidth: root.cardWidth
    contentHeight: root.cardHeight

    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)

      // The filters, as chips. Each one is a thing that was submitted, and
      // each one comes back out on its own — click the chip, or backspace
      // into it from an empty field.
      Flow {
        width: parent.width
        spacing: Style.space(4)
        visible: root.authenticated && !root.showSettings && root.filters.length > 0

        Repeater {
          model: root.filters

          Rectangle {
            required property int index
            required property var modelData

            height: chipRow.implicitHeight + Style.space(6)
            width: Math.min(chipRow.implicitWidth + Style.space(12), content.width)
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                           chipHover.hovered ? 0.22 : 0.12)

            HoverHandler { id: chipHover }
            TapHandler { onTapped: root.removeFilter(index) }

            Row {
              id: chipRow
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                // The label gives way before the card does.
                width: Math.min(implicitWidth, content.width - Style.space(32))
                text: Model.filterLabel(modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontMeta
                font.italic: modelData.kind === "jql"
                elide: Text.ElideRight
              }

              Text {
                text: "\u00d7"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fontMeta
              }
            }
          }
        }

        Button {
          fontFamily: root.fontFamily
          fontSize: root.fontBody
          visible: root.filters.length > 1
          text: "Clear all"
          foreground: root.foreground
          hasCursor: root.isAction("clear")
          onClicked: root.clearFilters()
        }
      }

      TextField {
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        id: field
        width: parent.width
        visible: root.authenticated && !root.showSettings
        foreground: root.foreground
        placeholderText: root.filters.length > 0
          ? "Narrow it further — text or JQL, Enter to add"
          : "Enter a ticket ID, search string or JQL."
        onAccepted: root.submit(text)
        onTextChanged: {
          if (!root.authenticated) return
          root.isJql = Model.looksLikeJql(text)
          var trimmed = text.trim()
          root.resetSelection()
          if (trimmed === "" && root.filters.length === 0) {
            root.clearResults()
            root.issue = null
            return
          }
          // JQL waits for Enter; a draft too short to search on leaves the
          // committed filters to search by themselves.
          if (root.isJql) { debounce.stop(); return }
          if (trimmed.length < root.minQuery && root.filters.length === 0) { debounce.stop(); return }
          debounce.restart()
        }
        Keys.onPressed: function(event) {
          // Backspace at the start of an empty field takes the last chip back
          // off, the way it does in every other chip field.
          if (event.key === Qt.Key_Backspace && field.text === "" && root.filters.length > 0) {
            root.removeFilter(root.filters.length - 1)
            event.accepted = true
            return
          }
          if (root.handleNavKey(event, true)) event.accepted = true
        }
        Keys.onEscapePressed: root.back()
        Keys.onTabPressed: function(event) {
          if (!root.switchPanel(event.modifiers & Qt.ShiftModifier ? -1 : 1)) event.accepted = false
        }
      }

      Text {
        width: parent.width
        visible: root.authenticated && !root.showSettings && !root.isJql && !root.loading
                 && root.issue === null && root.filters.length === 0
                 && field.text.trim().length > 0 && field.text.trim().length < root.minQuery
        text: "Keep typing — searches start at " + root.minQuery + " characters"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontMeta
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.authenticated && !root.showSettings && root.isJql
                 && !root.searching && !root.loading
        text: "JQL — press Enter to add it as a filter"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontMeta
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.searching && !root.loading
        text: "Searching…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.authState === "checking" || root.saving
        text: root.saving ? "Saving…" : "Checking Jira credentials…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        elide: Text.ElideRight
      }

      // The credentials form. Nothing can be looked up until it checks out,
      // so it replaces the ticket field rather than sitting next to it.
      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.showSettings && !root.saving

        Text {
          width: parent.width
          text: root.authenticated ? "Jira credentials" : "Connect to Jira"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.fontHeading
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: root.authError !== ""
          text: root.authError
          color: bar ? bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          text: "Site"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fontMeta
          elide: Text.ElideRight
        }

        TextField {
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          id: siteField
          width: parent.width
          foreground: root.foreground
          placeholderText: "yourteam.atlassian.net"
          onAccepted: emailField.forceActiveFocus()
          Keys.onPressed: function(event) {
            if (root.handleNavKey(event, false)) event.accepted = true
          }
          Keys.onEscapePressed: root.cancelSettings()
        }

        Text {
          width: parent.width
          text: "Account email"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fontMeta
          elide: Text.ElideRight
        }

        TextField {
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          id: emailField
          width: parent.width
          foreground: root.foreground
          placeholderText: "you@example.com"
          onAccepted: tokenField.forceActiveFocus()
          Keys.onPressed: function(event) {
            if (root.handleNavKey(event, false)) event.accepted = true
          }
          Keys.onEscapePressed: root.cancelSettings()
        }

        Text {
          width: parent.width
          text: "API token"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fontMeta
          elide: Text.ElideRight
        }

        // Stored with 0600 permissions outside the plugin; never read back
        // into the UI, which is why a blank field means "keep the stored one".
        TextField {
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          id: tokenField
          width: parent.width
          password: true
          foreground: root.foreground
          placeholderText: root.hasStoredToken ? "Leave blank to keep the stored token" : "Paste your API token"
          onAccepted: root.saveSettings()
          Keys.onPressed: function(event) {
            if (root.handleNavKey(event, false)) event.accepted = true
          }
          Keys.onEscapePressed: root.cancelSettings()
        }

        Text {
          width: parent.width
          text: "Create a token at id.atlassian.com/manage-profile/security/api-tokens"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fontMeta
          wrapMode: Text.Wrap
        }

        // Flow, not Row: a narrow card wraps the buttons onto another line
        // instead of pushing the last one past its edge.
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Button {
            fontFamily: root.fontFamily
            fontSize: root.fontBody
            text: "Save and connect"
            foreground: root.foreground
            hasCursor: root.isAction("save")
            onClicked: root.saveSettings()
          }

          Button {
            fontFamily: root.fontFamily
            fontSize: root.fontBody
            visible: root.authenticated
            text: "Cancel"
            foreground: root.foreground
            hasCursor: root.isAction("cancel")
            onClicked: root.cancelSettings()
          }

          Button {
            fontFamily: root.fontFamily
            fontSize: root.fontBody
            visible: root.hasStoredToken
            text: "Forget"
            foreground: root.foreground
            hasCursor: root.isAction("forget")
            onClicked: root.forgetSettings()
          }
        }
      }

      // Account line and its button sit together on the right edge of the card.
      Item {
        width: parent.width
        height: accountRow.height
        visible: root.authenticated && !root.showSettings && root.issue === null && !root.loading
                 && !root.searching && root.errorText === "" && root.results.length === 0
                 && root.filters.length === 0

        Row {
          id: accountRow
          anchors.right: parent.right
          spacing: Style.space(6)

          // A long account name elides rather than widening the row past the card.
          Text {
            width: Math.min(implicitWidth, parent.parent.width - credentialsButton.width - parent.spacing)
            anchors.verticalCenter: credentialsButton.verticalCenter
            text: root.authAccount !== "" ? "Signed in as " + root.authAccount : "Signed in"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontMeta
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
          }

          Button {
            fontFamily: root.fontFamily
            fontSize: root.fontBody
            id: credentialsButton
            text: "Change credentials"
            foreground: root.foreground
            hasCursor: root.isAction("credentials")
            onClicked: root.openSettings()
          }
        }
      }

      Text {
        width: parent.width
        visible: root.loading
        text: "Fetching…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: !root.loading && root.errorText !== ""
        text: root.errorText
        color: bar ? bar.urgent : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: root.fontBody
        wrapMode: Text.Wrap
      }

      // Up to 20 matches, newest first. Enter on a highlighted row, or a click,
      // asks for that ticket's full metadata.
      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.showResults && !root.loading

        Text {
          width: parent.width
          text: root.results.length + (root.results.length === 1 ? " match" : " matches")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.fontMeta
          elide: Text.ElideRight
        }

        // The list takes exactly the height its rows need, and only scrolls —
        // keeping the keyboard selection in view — once they outgrow the screen.
        Flickable {
          id: resultsView
          width: parent.width
          height: Math.min(resultsList.implicitHeight, root.maxResultsHeight)
          contentHeight: resultsList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          function revealSelected() {
            if (root.selected < 0 || root.selected >= resultsList.children.length) return
            var item = resultsList.children[root.selected]
            if (item.y < contentY) contentY = item.y
            else if (item.y + item.height > contentY + height) contentY = item.y + item.height - height
          }

          Column {
            id: resultsList
            width: resultsView.width
            spacing: Style.space(2)

            Repeater {
              model: root.results

              Rectangle {
                required property int index
                required property var modelData

                width: parent.width
                height: row.implicitHeight + Style.space(8)
                radius: Style.space(4)
                color: index === root.selected || hover.hovered
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : "transparent"

                HoverHandler { id: hover }

                TapHandler {
                  onTapped: {
                    root.selected = index
                    root.openResult(index)
                  }
                }

                Column {
                  id: row
                  x: Style.space(6)
                  y: Style.space(4)
                  width: parent.width - Style.space(12)
                  spacing: Style.space(2)

                  // Key and state read left to right; the issue type sits at
                  // the far right so the column scans as its own list.
                  Item {
                    width: parent.width
                    height: Math.max(heading.implicitHeight, issueType.implicitHeight)

                    Text {
                      id: heading
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Math.max(0, parent.width - issueType.width
                        - (issueType.width > 0 ? Style.space(4) : 0))
                      text: modelData.key + " · " + modelData.status
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontMeta
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      id: issueType
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      visible: modelData.type !== ""
                      width: visible ? Math.min(implicitWidth, parent.width * 0.4) : 0
                      text: modelData.type
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: root.fontMeta
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    width: parent.width
                    text: modelData.summary
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontBody
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.loading && root.issue !== null

        // The card is the ticket, so the card is the thing you press: Enter
        // opens it without a button to reach for first, and a click anywhere
        // on the metadata does the same for the mouse.
        Column {
          width: parent.width
          spacing: Style.space(6)

          HoverHandler {
            id: issueHover
            cursorShape: Qt.PointingHandCursor
          }

          TapHandler { onTapped: root.openIssue() }

          // Key and status on the left, the how-to-open hint pinned to the
          // right edge: the hint is an instruction, not another metadata
          // field, so it sits clear of the column the metadata reads down.
          Item {
            width: parent.width
            height: issueKey.implicitHeight

            Text {
              id: issueKey
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - (openHint.visible ? openHint.width + Style.space(8) : 0)
              text: root.issue ? root.issue.key + " · " + root.issue.status : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontHeading
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              id: openHint
              anchors.right: parent.right
              anchors.verticalCenter: issueKey.verticalCenter
              visible: root.issue && root.issue.url !== ""
              text: "Press Enter to open in browser"
              color: issueHover.hovered ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: root.fontMeta
            }
          }

          Text {
            width: parent.width
            text: root.issue ? root.issue.summary : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontBody
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            text: root.issue
              ? [root.issue.type, root.issue.priority, root.issue.assignee].filter(function(v) { return v !== "" }).join(" · ")
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontBody
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            visible: root.issue && root.issue.updated !== ""
            text: root.issue ? "Updated " + Model.formatUpdated(root.issue.updated) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontMeta
            elide: Text.ElideRight
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Button {
            fontFamily: root.fontFamily
            fontSize: root.fontBody
            visible: root.results.length > 0
            text: "Back to results"
            foreground: root.foreground
            hasCursor: root.isAction("back")
            onClicked: root.issue = null
          }
        }
      }
    }
  }
}
