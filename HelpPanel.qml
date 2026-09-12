import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Offline help for Omarchy: live search over this machine's keybindings, the
// omarchy CLI, and the manual pinned to the installed version, plus a chat
// with the local model about anything. When Omarchy cannot do what the user
// wants, "Build it" hands the feature to Rix or a coding client.
//
// The window is a normal toplevel (FloatingWindow), not an overlay: it stays
// on the workspace while a command runs in a terminal or the manual opens
// next to it. Host contract (kind "panel", keepLoaded): the shell injects
// `shell` and `manifest`, calls open()/close(), reads `opened`; we call
// shell.hide(id) when the user closes the window.
//
// Two helper processes, both held open while the window is visible:
//   --search-daemon  one query line in, one JSON line out, ~1ms a keystroke
//   --chat-daemon    one JSON request in, streamed JSON deltas out
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "io.github.modpunk.omarchy-help"
  readonly property string agent: Quickshell.env("HOME") + "/.local/bin/omarchy-local-agent"
  readonly property bool opened: window.visible
  property bool closingFromHost: false

  property string mode: "search"        // "search" | "chat"
  property string filterText: ""
  property int selectedIndex: 0
  property string notice: ""
  property string selectedKind: ""      // kind of the selected row, for the footer hint
  onSelectedIndexChanged: syncSelected()
  function syncSelected() { var r = selectableAt(selectedIndex); selectedKind = r ? r.kind : "" }

  // chat state
  property string chatSid: ""           // manual section pinned for this conversation
  property string chatHeading: ""
  property string chatSource: ""
  property bool chatBusy: false
  property bool chatSlow: false
  property int requestId: 0
  property int streamIndex: -1
  property string chatMode: ""          // "omarchy" | "general", from the daemon

  // build state ("Build it"): the sheet, the scene, and the reply
  property bool buildOpen: false
  property bool buildBusy: false
  property var buildOpts: null
  property string buildTarget: "plugin"  // "plugin" | "webapp"
  property string buildVia: "client"     // "client" | "rix"
  property string buildError: ""
  property int buildRequestId: 0         // negative ids: never collide with chat ids

  property color background: Color.menu.background
  // Solid backdrop for screenshots (the menu surface is translucent by theme);
  // toggled over IPC: omarchy-shell shell call <id> setSolid 1|0
  property bool solid: false
  function setSolid(flag) { solid = String(flag) === "1" || flag === true }
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  readonly property int inputLine: Math.round(Style.font.heading * 1.45)
  readonly property int footerHeight: Math.max(Style.space(18), Style.font.caption + Style.space(6))

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    closingFromHost = false
    if (results.count === 0) rebuildEmpty()
    window.visible = true
    focusTimer.restart()
  }
  function close() { closingFromHost = true; window.visible = false; closingFromHost = false }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else window.visible = false
  }
  function toggle() { if (window.visible) requestClose(); else open("{}") }
  function focusInput() { Qt.callLater(function() { input.forceActiveFocus() }) }

  // Esc walks back: chat -> search, query -> empty, empty -> close.
  function back() {
    if (doIt.visible) { doIt.skip(); return }
    if (buildOpen) { closeBuild(); return }
    if (mode === "chat") { leaveChat(); return }
    if (input.text !== "") { input.text = ""; return }
    requestClose()
  }

  // ---- search -------------------------------------------------------------

  function onInputChanged(text) {
    if (mode !== "search") return
    var q = text.replace(/\s+/g, " ").trim()
    filterText = q
    selectedIndex = 0
    if (!q) { rebuildEmpty(); return }
    if (searchProc.running) searchProc.write(q + "\n")
  }

  function rebuildEmpty() {
    results.clear()
    results.append({ kind: "hint", primary: "Type to search keybindings, commands and the manual",
                     secondary: "", sid: "" })
    results.append({ kind: "hint", primary: "Examples:  nightlight  ·  screenshot  ·  how do I change my theme  ·  or ask anything",
                     secondary: "", sid: "" })
    results.append({ kind: "hint", primary: "Enter runs a command, opens the manual, or starts a chat.  Shift+Enter adds a line.",
                     secondary: "", sid: "" })
    syncSelected()
  }

  function applyResults(payload) {
    var data
    try { data = JSON.parse(payload) } catch (e) { return }
    if (!data || data.query !== filterText) return   // a later keystroke won

    results.clear()
    if (filterText.length > 2)
      results.append({ kind: "ask", primary: "Chat with the local agent: " + filterText,
                       secondary: "answers anything; Omarchy questions come from the manual", sid: "" })

    var i
    for (i = 0; i < (data.binds || []).length; i++)
      results.append({ kind: "bind", primary: data.binds[i].keys,
                       secondary: data.binds[i].description, sid: "" })
    for (i = 0; i < (data.commands || []).length; i++)
      results.append({ kind: "command",
                       primary: (data.commands[i].route + " " + (data.commands[i].args || "")).trim(),
                       secondary: data.commands[i].summary || "", sid: "" })
    for (i = 0; i < (data.sections || []).length; i++) {
      var head = data.sections[i].heading
      var chap = data.sections[i].chapter
      results.append({ kind: "section", primary: head,
                       secondary: (chap === head ? "" : chap),
                       sid: data.sections[i].sid })
    }
    if (results.count === 0)
      results.append({ kind: "hint", primary: "Nothing matched “" + filterText + "”", secondary: "", sid: "" })
    selectedIndex = 0
    syncSelected()
  }

  function selectableAt(i) {
    if (i < 0 || i >= results.count) return null
    var r = results.get(i)
    return r.kind === "hint" ? null : r
  }
  function selected() { return selectableAt(selectedIndex) }

  function move(delta) {
    if (results.count === 0) return
    var i = selectedIndex
    for (var n = 0; n < results.count; n++) {
      i = (i + delta + results.count) % results.count
      if (selectableAt(i)) { selectedIndex = i; resultList.positionViewAtIndex(i, ListView.Contain); return }
    }
  }

  // ---- actions ------------------------------------------------------------

  function primaryLabel(kind) {
    // "Do it." here too: the search row and the chat step are the same act,
    // so they should not be labelled differently.
    return kind === "command" ? "Do it." : kind === "section" ? "Open manual" : kind === "ask" ? "Chat" : kind === "bind" ? "Copy" : ""
  }
  function secondaryLabel(kind) {
    return kind === "command" ? "Copy" : kind === "section" ? "Explain" : ""
  }

  function primary(r) {
    if (!r) return
    if (r.kind === "command") runCommand(r.primary)
    else if (r.kind === "section") openSection(r.sid)
    else if (r.kind === "ask") startChat(filterText, "", "")
    else if (r.kind === "bind") copy(r.primary)
  }
  function secondary(r) {
    if (!r) return
    if (r.kind === "command") copy(r.primary)
    else if (r.kind === "section") startChat(filterText || ("Explain " + r.primary), r.sid, r.primary)
    else if (r.kind === "bind") copy(r.primary)
  }

  function activate() {
    if (mode === "chat") { var q = input.text.trim(); if (q) { input.text = ""; send(q) }; return }
    primary(selected())
  }

  function copy(text) {
    Quickshell.execDetached(["wl-copy", "--", text])
    flash("Copied  " + text)
  }
  // The command opens on an editable prompt in a floating terminal: Enter
  // runs it, placeholders can be fixed first. The CLI builds the argv.
  function runCommand(cmd) {
    if (refusedRe.test(cmd)) { flash("Blocked by policy:  " + cmd); return }
    Quickshell.execDetached([agent, "--run", cmd])
    flash("Opened a terminal with  " + cmd)
  }
  function openSection(sid) {
    if (!sid) return
    Quickshell.execDetached([agent, "--open-section", sid])
    flash("Opening the manual at that section")
  }
  function flash(text) { notice = text; noticeTimer.restart() }

  // Last-resort guard mirroring the CLI's hard refusals; the CLI's
  // command_policy() is the source of truth and runs again on every launch.
  readonly property var refusedRe: /(^|[\s;&|(`$])(sudo|pkexec|doas|su|dd|mkfs|reboot|shutdown|poweroff|halt|shred)(\s|\.|$)|(^|[\s;&|(`$])rm\s+-[A-Za-z]*[rR]|(^|[\s;&|(`$])systemctl\s+(?!--user)|\|\s*(sh|bash|zsh|fish|python3?)(\s|$)/
  function stepsOf(json) { try { var v = JSON.parse(json || "[]"); return Array.isArray(v) ? v : [] } catch (e) { return [] } }
  function stepNote(st) {
    var parts = []
    if (st.verdict === "refuse") parts.push(st.reason)
    else if (st.verdict === "run") parts.push("allowlisted, runs on click")
    else parts.push("opens on an editable prompt: " + st.reason)
    if (st.writes && st.writes.length) parts.push("writes " + st.writes.join(", "))
    if (st.reads && st.reads.length) parts.push("reads " + st.reads.join(", "))
    if (st.resolved && st.resolved !== st.cmd) parts.push("filled in from  " + st.cmd)
    return parts.join("   ·   ")
  }

  // ---- chat ---------------------------------------------------------------

  function startChat(query, sid, heading) {
    if (!query) return
    messages.clear()
    chatSid = sid || ""
    chatHeading = heading || ""
    chatSource = ""
    mode = "chat"
    input.text = ""
    send(query)
    focusInput()
  }
  function newChat() {
    messages.clear()
    chatSid = ""; chatHeading = ""; chatSource = ""; chatMode = ""
    chatBusy = false; chatSlow = false; streamIndex = -1
    requestId++            // orphan any reply still streaming
    input.text = ""
    focusInput()
  }
  function leaveChat() {
    mode = "search"
    input.text = filterText
    focusInput()
  }
  function send(query) {
    if (!query) return
    if (chatBusy) { flash("Wait for the current answer first"); return }
    var history = []
    for (var i = 0; i < messages.count; i++) {
      var m = messages.get(i)
      if (m.text) history.push({ role: m.role, content: m.text })
    }
    messages.append({ role: "user", text: query, sid: "", heading: "", source: "", steps: "[]", build: "" })
    messages.append({ role: "assistant", text: "", sid: "", heading: "", source: "", steps: "[]", build: "" })
    streamIndex = messages.count - 1
    chatBusy = true; chatSlow = false; slowTimer.restart()
    requestId++
    var req = { id: requestId, query: query, history: history, sid: chatSid }
    if (chatProc.running) chatProc.write(JSON.stringify(req) + "\n")
    else finishWith("The helper is not running.")
    transcript.positionViewAtEnd()
  }
  function onChatLine(line) {
    var d
    try { d = JSON.parse(line) } catch (e) { return }
    if (d && typeof d.id === "number" && d.id < 0) { onBuildReply(d); return }
    if (!d || d.id !== requestId) return
    if (streamIndex < 0 || streamIndex >= messages.count) return
    if (d.status) {
      chatMode = d.mode || ""
      if (d.sid) { chatSid = d.sid; chatHeading = d.heading || ""; chatSource = d.source || "" }
      return
    }
    if (d.delta !== undefined) {
      slowTimer.stop(); chatSlow = false
      messages.setProperty(streamIndex, "text", messages.get(streamIndex).text + d.delta)
      transcript.positionViewAtEnd()
      return
    }
    if (d.done) {
      // The daemon strips the "BUILD:" marker line; take its cleaned text.
      if (d.text !== undefined && d.text !== "") messages.setProperty(streamIndex, "text", d.text)
      messages.setProperty(streamIndex, "build", d.build ? d.build.feature : "")
      stamp(d)
      messages.setProperty(streamIndex, "steps", JSON.stringify(d.steps || []))
      finishWith("")
      return
    }
    if (d.error) {
      var t = d.error
      if (d.fallback) t += "\n\nFrom the manual (" + (d.heading || "") + "):\n\n" + d.fallback
      stamp(d)
      finishWith(t)
    }
  }
  function stamp(d) {
    if (d.sid) { chatSid = d.sid; chatHeading = d.heading || ""; chatSource = d.source || "" }
    messages.setProperty(streamIndex, "sid", d.sid || "")
    messages.setProperty(streamIndex, "heading", d.heading || "")
    messages.setProperty(streamIndex, "source", d.source || "")
  }
  function finishWith(text) {
    slowTimer.stop(); chatSlow = false; chatBusy = false
    if (streamIndex >= 0 && streamIndex < messages.count) {
      var cur = messages.get(streamIndex).text
      if (text) messages.setProperty(streamIndex, "text", cur ? cur + "\n\n" + text : text)
      else if (!cur) messages.setProperty(streamIndex, "text", "No answer came back.")
    }
    streamIndex = -1
    transcript.positionViewAtEnd()
  }

  // ---- build it ---------------------------------------------------------

  function chatHistory() {
    var h = []
    for (var i = 0; i < messages.count; i++) {
      var m = messages.get(i)
      if (m.text) h.push({ role: m.role, content: m.text })
    }
    return h
  }
  function lastQuestion() {
    for (var i = messages.count - 1; i >= 0; i--)
      if (messages.get(i).role === "user") return messages.get(i).text
    return filterText
  }
  function openBuild(feature, brief) {
    buildFeatureInput.text = feature || ""
    buildBriefInput.text = brief || feature || ""
    buildTarget = /\b(web ?app|website|site|saas|online|server|api|dashboard|sign ?up|accounts?)\b/i.test((feature || "") + " " + (brief || "")) ? "webapp" : "plugin"
    buildVia = "client"
    buildError = ""
    buildBusy = false
    buildOpen = true
    buildRequestId--
    if (chatProc.running) chatProc.write(JSON.stringify({ id: buildRequestId, build_options: true }) + "\n")
    Qt.callLater(function() { (feature ? buildBriefInput : buildFeatureInput).forceActiveFocus() })
  }
  function closeBuild() { buildOpen = false; buildBusy = false; doIt.cancel(); focusInput() }
  function viaAvailable(via) {
    if (!buildOpts) return false
    return via === "rix" ? buildOpts.rix_available : buildOpts.client_available
  }
  function buildReady() {
    return buildOpen && !buildBusy && !doIt.visible && buildFeatureInput.text.trim() !== "" && viaAvailable(buildVia)
  }
  function doItBuild() {
    if (!buildReady()) {
      if (buildFeatureInput.text.trim() === "") buildError = "Say what to build first."
      else if (buildOpts && !viaAvailable(buildVia))
        buildError = buildVia === "rix" ? "Rix is " + buildOpts.rix_where + "." : buildOpts.client_label + " " + buildOpts.client_where + "."
      return
    }
    buildError = ""
    doIt.start()
  }
  // Called when the scene finishes (or is skipped). Never called if the
  // window closed mid-scene: cancel() stops it without finishing.
  function sendBuild() {
    if (!buildOpen || !window.visible) return
    if (!chatProc.running) { buildError = "The helper is not running."; return }
    buildBusy = true
    buildRequestId--
    chatProc.write(JSON.stringify({ id: buildRequestId, build: {
      target: buildTarget, via: buildVia,
      feature: buildFeatureInput.text.trim(), brief: buildBriefInput.text.trim(),
      transcript: chatHistory() } }) + "\n")
  }
  function onBuildReply(d) {
    if (d.build_options) { buildOpts = d.build_options; return }
    if (d.id !== buildRequestId) return
    buildBusy = false
    if (d.built) {
      buildOpen = false
      flash("Building with " + d.built.via + " in  " + d.built.path)
      focusInput()
    } else if (d.error) {
      buildError = d.error + (d.hint ? "\n" + d.hint : "") + (d.path ? "\nProject folder: " + d.path : "")
    }
  }
  function whereLine() {
    if (!buildOpts) return "Checking what is available…"
    var local = buildVia === "rix" ? buildOpts.rix_local : buildOpts.client_local
    var name = buildVia === "rix" ? "Rix" : buildOpts.client_label
    var where = buildVia === "rix" ? buildOpts.rix_where : buildOpts.client_where
    return name + " " + where + (viaAvailable(buildVia)
      ? (local ? ".  Nothing leaves this computer." : ".  The brief and this conversation leave this computer.")
      : ".")
  }

  ListModel { id: results }
  ListModel { id: messages }

  Timer { id: noticeTimer; interval: 2200; onTriggered: root.notice = "" }
  Timer { id: slowTimer; interval: 6000; onTriggered: root.chatSlow = true }
  Timer {
    id: focusTimer; interval: 150
    onTriggered: { Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "title:^Omarchy Help$"]); root.focusInput() }
  }

  Process {
    id: searchProc
    command: [root.agent, "--search-daemon"]
    running: window.visible
    stdinEnabled: true
    stdout: SplitParser { splitMarker: "\n"; onRead: function(line) { if (line) root.applyResults(line) } }
  }
  Process {
    id: chatProc
    command: [root.agent, "--chat-daemon"]
    running: window.visible
    stdinEnabled: true
    stdout: SplitParser { splitMarker: "\n"; onRead: function(line) { if (line) root.onChatLine(line) } }
    onExited: function(code) { if (root.chatBusy) root.finishWith("The helper exited with code " + code + ".") }
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    visible: false                       // keepLoaded mounts us at shell start
    title: "Omarchy Help"
    color: root.solid ? Qt.rgba(root.background.r, root.background.g, root.background.b, 1) : root.background
    implicitWidth: 760
    implicitHeight: 580
    minimumSize: Qt.size(480, 320)

    onVisibleChanged: {
      if (!visible) { doIt.cancel(); root.buildOpen = false; root.buildBusy = false }
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      Column {
        anchors.fill: parent
        anchors.margins: root.contentMargin
        spacing: root.contentSpacing

        // ---- input: wraps to the window width, grows to six lines ----
        Rectangle {
          id: inputBox
          width: parent.width
          height: inputFlick.height + Style.spacing.inputPaddingY * 2
          radius: Style.cornerRadius
          color: root.faint
          border.width: 1
          border.color: input.activeFocus ? root.accent : root.border

          Flickable {
            id: inputFlick
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.topMargin: Style.spacing.inputPaddingY
            height: Math.max(root.inputLine, Math.min(input.contentHeight, root.inputLine * 6))
            contentWidth: width
            contentHeight: input.contentHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            function ensureVisible(r) {
              if (contentY >= r.y) contentY = r.y
              else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }

            TextEdit {
              id: input
              width: inputFlick.width
              wrapMode: TextEdit.Wrap
              color: root.foreground
              selectionColor: root.accent
              selectedTextColor: root.background
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              selectByMouse: true
              focus: true
              onCursorRectangleChanged: inputFlick.ensureVisible(cursorRectangle)
              onTextChanged: root.onInputChanged(text)

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true }
                else if (enter && (event.modifiers & Qt.ShiftModifier)) { event.accepted = false }   // newline
                else if (enter && (event.modifiers & Qt.ControlModifier)) { root.secondary(root.selected()); event.accepted = true }
                else if (enter) { root.activate(); event.accepted = true }
                else if (event.key === Qt.Key_Up && root.mode === "search") { root.move(-1); event.accepted = true }
                else if (event.key === Qt.Key_Down && root.mode === "search") { root.move(1); event.accepted = true }
                else if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) { root.newChat(); event.accepted = true }
              }

              Text {
                visible: input.text === "" && input.preeditText === ""
                textFormat: Text.PlainText
                text: root.mode === "chat" ? "Ask a follow-up…" : "Search Omarchy help, or ask a question…"
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
              }
            }
          }
        }

        // ---- chat context line ----
        Row {
          width: parent.width
          visible: root.mode === "chat"
          spacing: Style.spacing.rowGap
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - chatActions.width - parent.spacing
            textFormat: Text.PlainText
            text: root.chatHeading ? "Reading:  " + root.chatHeading + (root.chatSource ? "   ·   " + root.chatSource : "")
                : root.chatMode === "general" ? "Answering from general knowledge" : "Picking a manual section…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
          Row {
            id: chatActions
            spacing: Style.space(4)
            Button { text: "Open manual"; bordered: true; fontSize: Style.font.caption; foreground: root.foreground; fontFamily: root.fontFamily; visible: root.chatSid !== ""; onClicked: root.openSection(root.chatSid) }
            Button { text: "Build something new…"; bordered: true; fontSize: Style.font.caption; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.openBuild("", root.lastQuestion()) }
            Button { text: "New chat"; bordered: true; fontSize: Style.font.caption; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.newChat() }
            Button { text: "Back to search"; bordered: true; fontSize: Style.font.caption; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: root.leaveChat() }
          }
        }

        // ---- body: results, or the chat transcript ----
        Item {
          width: parent.width
          height: parent.height - inputBox.height - root.footerHeight - root.contentSpacing * 2
                  - (root.mode === "chat" ? chatActions.height + root.contentSpacing : 0)

          ListView {
            id: resultList
            anchors.fill: parent
            visible: root.mode === "search"
            model: results
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(2)

            delegate: Rectangle {
              id: row
              required property int index
              required property var model
              readonly property bool current: index === root.selectedIndex && model.kind !== "hint"
              width: resultList.width
              height: model.secondary ? Style.space(44) : Style.space(30)
              radius: Style.space(6)
              color: current ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                enabled: row.model.kind !== "hint"
                hoverEnabled: true
                onClicked: { root.selectedIndex = row.index; root.primary(root.selected()) }
                onPositionChanged: root.selectedIndex = row.index
              }

              Row {
                anchors.left: parent.left
                anchors.right: actions.left
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  textFormat: Text.PlainText
                  text: row.model.kind === "bind" ? "⌨"
                      : row.model.kind === "command" ? "❯"
                      : row.model.kind === "section" ? "▤"
                      : row.model.kind === "ask" ? "✦" : " "
                  color: row.current ? root.selectedText : root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(26)
                  spacing: Style.space(1)
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: row.model.primary
                    color: row.current ? root.selectedText : root.foreground
                    opacity: row.model.kind === "hint" ? 0.55 : 1
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: !!row.model.secondary
                    textFormat: Text.PlainText
                    text: row.model.secondary
                    color: row.current ? root.selectedText : root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              // Per-row actions; shown on the selected row so the list stays quiet.
              Row {
                id: actions
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                visible: row.current
                width: visible ? implicitWidth : 0      // a hidden Row still reserves its width
                Button {
                  visible: text !== ""
                  text: root.primaryLabel(row.model.kind)
                  bordered: true; fontSize: Style.font.caption
                  foreground: row.current ? root.selectedText : root.foreground; fontFamily: root.fontFamily
                  onClicked: root.primary(results.get(row.index))
                }
                Button {
                  visible: text !== ""
                  text: root.secondaryLabel(row.model.kind)
                  bordered: true; fontSize: Style.font.caption
                  foreground: row.current ? root.selectedText : root.foreground; fontFamily: root.fontFamily
                  onClicked: root.secondary(results.get(row.index))
                }
              }
            }
          }

          ListView {
            id: transcript
            anchors.fill: parent
            visible: root.mode === "chat"
            model: messages
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(10)

            delegate: Column {
              id: msg
              required property int index
              required property var model
              readonly property bool mine: model.role === "user"
              readonly property bool streaming: index === root.streamIndex && root.chatBusy
              width: transcript.width
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: msg.mine ? "You" : "Local agent"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Rectangle {
                width: parent.width
                height: body.implicitHeight + Style.space(16)
                radius: Style.space(8)
                color: msg.mine ? root.faint : "transparent"
                border.width: msg.mine ? 0 : 1
                border.color: root.border
                Text {
                  id: body
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  textFormat: msg.mine ? Text.PlainText : Text.MarkdownText
                  text: msg.model.text ? msg.model.text
                      : (msg.streaming ? (root.chatSlow ? "Still waiting for the local model. An agent may be using it right now…" : "Thinking…") : "")
                  color: root.foreground
                  opacity: msg.model.text ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
              }
              Column {
                width: parent.width
                visible: !msg.mine && !msg.streaming && steps.length > 0
                spacing: Style.space(6)
                readonly property var steps: root.stepsOf(msg.model.steps)
                Text {
                  textFormat: Text.PlainText
                  text: "Steps. Each one runs only when you click it; what it touches is shown first."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: parent.steps
                  delegate: Column {
                    id: step
                    required property var modelData
                    readonly property string cmd: modelData.resolved || modelData.cmd
                    readonly property bool blocked: modelData.verdict === "refuse"
                    width: parent.width
                    spacing: Style.space(1)

                    // "Do it." — the step button, with a short charge-up before
                    // the command fires. The delay is not decoration alone: it
                    // is the last moment to see what is about to run, and it
                    // makes a click feel deliberate rather than incidental.
                    // Blocked steps never animate and never fire.
                    property bool charging: false

                    Item {
                      width: parent.width
                      height: doBtn.implicitHeight

                      Button {
                        id: doBtn
                        anchors.fill: parent
                        text: (step.blocked ? "Blocked:  " : "Do it.   ")
                              + (step.cmd.length > 88 ? step.cmd.slice(0, 88) + "…" : step.cmd)
                        bordered: true; fontSize: Style.font.caption; leftAlign: true
                        foreground: step.blocked ? root.dim
                                    : step.charging ? root.accent : root.foreground
                        fontFamily: root.fontFamily
                        enabled: !step.blocked && !step.charging
                        onClicked: charge.start()
                      }

                      // Force lightning: thin arcs raked across the button,
                      // struck in sequence rather than all at once.
                      Item {
                        anchors.fill: parent
                        visible: step.charging
                        clip: true
                        Repeater {
                          model: 7
                          delegate: Rectangle {
                            required property int index
                            width: Math.max(1, Style.space(1))
                            height: parent.height * 2.4
                            y: -parent.height * 0.7
                            x: parent.width * (0.08 + 0.13 * index)
                            rotation: index % 2 ? 18 : -18
                            color: root.accent
                            opacity: 0
                            SequentialAnimation on opacity {
                              running: step.charging
                              PauseAnimation { duration: 40 * index }
                              NumberAnimation { to: 0.85; duration: 60 }
                              NumberAnimation { to: 0; duration: 150 }
                            }
                          }
                        }
                      }

                      // A wash of accent that swells and releases as it fires.
                      Rectangle {
                        id: wash
                        anchors.fill: parent
                        radius: Style.space(4)
                        color: root.accent
                        opacity: 0
                      }
                    }

                    SequentialAnimation {
                      id: charge
                      ScriptAction { script: step.charging = true }
                      NumberAnimation { target: wash; property: "opacity"; to: 0.22; duration: 320 }
                      NumberAnimation { target: wash; property: "opacity"; to: 0; duration: 260 }
                      ScriptAction {
                        script: {
                          step.charging = false
                          root.runCommand(step.cmd)
                        }
                      }
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.stepNote(step.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }
                  }
                }
              }
              Rectangle {
                width: parent.width
                visible: !msg.mine && !msg.streaming && msg.model.build !== ""
                height: visible ? buildRow.implicitHeight + Style.space(12) : 0
                radius: Style.space(6)
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
                border.width: 1
                border.color: root.accent
                Row {
                  id: buildRow
                  anchors.left: parent.left; anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - buildBtn.width - parent.spacing
                    textFormat: Text.PlainText
                    text: "Not built in yet:  " + msg.model.build
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                  }
                  Button {
                    id: buildBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Build it…"; bordered: true; fontSize: Style.font.caption
                    foreground: root.accent; fontFamily: root.fontFamily
                    onClicked: root.openBuild(msg.model.build, root.lastQuestion())
                  }
                }
              }
              Row {
                visible: !msg.mine && msg.model.sid !== ""
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Source:  " + msg.model.heading + "  ·  " + msg.model.source
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
                Button {
                  text: "Open manual"; bordered: true; fontSize: Style.font.caption
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.openSection(msg.model.sid)
                }
              }
            }
          }
        }

        // ---- footer hint ----
        Item {
          width: parent.width
          height: root.footerHeight
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.notice ? root.notice
                : root.buildOpen ? "ctrl+↵ do it   tab next field   esc cancel"
                : root.mode === "chat" ? "↵ send   ⇧↵ new line   ctrl+n new chat   esc back to search"
                : (function() {
                    var k = root.selectedKind
                    var p = root.primaryLabel(k), s = root.secondaryLabel(k)
                    var hint = p ? "↵ " + p.toLowerCase() : "↵ go"
                    if (s) hint += "   ctrl+↵ " + s.toLowerCase()
                    return "↑↓ move   " + hint + "   ⇧↵ new line   esc close"
                  })()
            color: root.foreground
            opacity: root.notice ? 0.9 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // ---- build sheet ----
      Rectangle {
        id: buildSheet
        anchors.fill: parent
        anchors.margins: root.contentMargin
        anchors.bottomMargin: root.contentMargin + root.footerHeight + root.contentSpacing
        visible: root.buildOpen
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.98)
        radius: Style.cornerRadius
        border.width: 1
        border.color: root.accent
        MouseArea { anchors.fill: parent }        // keep clicks off the transcript beneath

        function keys(event) {
          var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true }
          else if (enter && (event.modifiers & Qt.ControlModifier)) { root.doItBuild(); event.accepted = true }
        }

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(14)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "Build it"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text { textFormat: Text.PlainText; text: "What to build"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Rectangle {
            width: parent.width
            height: buildFeatureInput.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: root.faint
            border.width: 1
            border.color: buildFeatureInput.activeFocus ? root.accent : root.border
            TextInput {
              id: buildFeatureInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              color: root.foreground
              selectionColor: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              clip: true
              KeyNavigation.tab: buildBriefInput
              Keys.onPressed: function(event) { buildSheet.keys(event) }
              onAccepted: buildBriefInput.forceActiveFocus()
            }
          }

          Row {
            spacing: Style.space(6)
            Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(64); textFormat: Text.PlainText; text: "As"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Button { text: "Omarchy plugin"; bordered: true; selected: root.buildTarget === "plugin"; fontSize: Style.font.caption; foreground: root.buildTarget === "plugin" ? root.accent : root.foreground; fontFamily: root.fontFamily; onClicked: root.buildTarget = "plugin" }
            Button { text: "Web app on omarchy.fans cloud"; bordered: true; selected: root.buildTarget === "webapp"; fontSize: Style.font.caption; foreground: root.buildTarget === "webapp" ? root.accent : root.foreground; fontFamily: root.fontFamily; onClicked: root.buildTarget = "webapp" }
          }
          Row {
            spacing: Style.space(6)
            Text { anchors.verticalCenter: parent.verticalCenter; width: Style.space(64); textFormat: Text.PlainText; text: "Built by"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Button {
              text: (root.buildOpts ? root.buildOpts.client_label : "Coding agent") + ", start coding now"
              bordered: true; selected: root.buildVia === "client"; fontSize: Style.font.caption
              foreground: root.buildVia === "client" ? root.accent : root.foreground; fontFamily: root.fontFamily
              onClicked: root.buildVia = "client"
            }
            Button {
              text: "Rix, plan and orchestrate"
              bordered: true; selected: root.buildVia === "rix"; fontSize: Style.font.caption
              foreground: root.buildVia === "rix" ? root.accent : root.foreground; fontFamily: root.fontFamily
              onClicked: root.buildVia = "rix"
            }
          }

          Text { textFormat: Text.PlainText; text: "Brief (edit freely: this is what the builder reads)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Rectangle {
            width: parent.width
            height: Math.max(Style.space(60), parent.height - y - whereText.height - (buildErrorText.visible ? buildErrorText.height + Style.space(8) : 0) - actionsRow.height - Style.space(8) * 2)
            radius: Style.space(6)
            color: root.faint
            border.width: 1
            border.color: buildBriefInput.activeFocus ? root.accent : root.border
            Flickable {
              id: briefFlick
              anchors.fill: parent
              anchors.margins: Style.space(6)
              contentWidth: width
              contentHeight: buildBriefInput.contentHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              TextEdit {
                id: buildBriefInput
                width: briefFlick.width
                wrapMode: TextEdit.Wrap
                color: root.foreground
                selectionColor: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                selectByMouse: true
                KeyNavigation.tab: buildFeatureInput
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) { buildSheet.keys(event) }
              }
            }
          }

          Text {
            id: whereText
            width: parent.width
            textFormat: Text.PlainText
            text: root.whereLine()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
          Text {
            id: buildErrorText
            width: parent.width
            visible: root.buildError !== ""
            textFormat: Text.PlainText
            text: root.buildError
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
          Row {
            id: actionsRow
            spacing: Style.space(6)
            Button {
              text: root.buildBusy ? "Starting…" : "Do it."
              bordered: true; fontSize: Style.font.body
              foreground: root.buildReady() ? root.accent : root.dim; fontFamily: root.fontFamily
              enabled: !root.buildBusy
              onClicked: root.doItBuild()
            }
            Button {
              text: "Cancel"; bordered: true; fontSize: Style.font.body
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.closeBuild()
            }
          }
        }
      }

      // ---- the "Do it." scene: plays, then hands off ----
      DoItScene {
        id: doIt
        anchors.fill: parent
        foreground: root.foreground
        accent: root.accent
        background: root.background
        fontFamily: root.fontFamily
        onFinished: root.sendBuild()
      }
    }
  }
}
