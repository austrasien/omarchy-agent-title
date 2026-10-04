import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons as Omarchy

Item {
  id: overlayRoot

  property var shell: null
  property var manifest: null

  // Keep in sync with pad top in ~/.config/foot/agent.ini.
  readonly property int barHeight: 22
  readonly property int sidePad: Omarchy.Style.space(10)
  property color fillColor: Omarchy.Color.background
  // Instantiator delegates cannot reliably bind Color.* ; pass hex on the model.
  property string accentHex: "#e68e0d"
  readonly property string forgeAccentHex: "#cba6f7"
  property string fgHex: "#bebebe"
  property var queryByAddress: ({})
  property var liveVisibleAddresses: ({})
  property double nowMs: Date.now()
  readonly property int barExclusiveFallback: 30
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string lastQueryBin: homeDir + "/.config/omarchy/plugins/austraz.agent-title/last-query.py"
  readonly property string queryFile: (Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")) + "/omarchy/agent-title/queries.json"

  function open(_payload) {}
  function close() {}
  function toggle() {}

  function parseTheme(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*(accent|foreground)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (!match)
        continue
      if (match[1] === "accent")
        overlayRoot.accentHex = match[2]
      else
        overlayRoot.fgHex = match[2]
    }
  }

  function canonAddress(raw) {
    var s = String(raw || "")
    var m = s.match(/0x[0-9a-fA-F]+/)
    return m ? m[0].toLowerCase() : s.toLowerCase()
  }

  function lookup(address) {
    var map = overlayRoot.queryByAddress
    var key = overlayRoot.canonAddress(address)
    if (!map || !key)
      return null
    return map[key] || map[address] || map["0x" + key] || null
  }

  function queryFor(address) {
    var v = overlayRoot.lookup(address)
    if (!v)
      return ""
    if (typeof v === "string")
      return v
    return String(v.query || "")
  }

  function responseAtFor(address) {
    var v = overlayRoot.lookup(address)
    if (!v || typeof v === "string")
      return 0
    return Number(v.lastResponseAt) || 0
  }

  function waitingForPromptFor(address) {
    var v = overlayRoot.lookup(address)
    if (!v || typeof v === "string")
      return true
    return !!v.waitingForPrompt
  }

  function conversationBusy(raw) {
    var t = String(raw || "")
    if (/^Working/i.test(t))
      return true
    if (/Waiting for confirmation/i.test(t))
      return true
    return false
  }

  function formatAge(ms) {
    var total = Math.max(0, Math.floor(ms / 1000))
    var d = Math.floor(total / 86400)
    var h = Math.floor((total % 86400) / 3600)
    var m = Math.floor((total % 3600) / 60)
    var s = total % 60
    var parts = []
    if (d > 0)
      parts.push(d + "d")
    if (h > 0)
      parts.push(h + "hr")
    if (m > 0)
      parts.push(m + "min")
    parts.push(s + "s")
    return parts.join(" ")
  }

  function applyQueries(raw) {
    var obj = ({})
    try {
      obj = JSON.parse(String(raw || "").replace(/^\s+|\s+$/g, "") || "{}")
    } catch (e) {
      obj = ({})
    }
    var canon = ({})
    for (var k in obj)
      canon[overlayRoot.canonAddress(k)] = obj[k]
    overlayRoot.queryByAddress = canon
    for (var i = 0; i < windows.count; i++) {
      var addr = windows.get(i).address
      windows.setProperty(i, "lastQuery", overlayRoot.queryFor(addr))
      windows.setProperty(i, "lastResponseAt", overlayRoot.responseAtFor(addr))
      windows.setProperty(i, "waitingForPrompt", overlayRoot.waitingForPromptFor(addr))
    }
  }

  function kickQueries() {
    if (queryProc.running)
      return
    queryProc.running = true
  }

  FileView {
    path: Omarchy.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: overlayRoot.parseTheme(text())
    onFileChanged: reload()
  }

  FileView {
    path: overlayRoot.queryFile
    watchChanges: true
    printErrors: false
    onLoaded: overlayRoot.applyQueries(text())
    onFileChanged: reload()
  }

  function isAgentClass(winClass) {
    var c = String(winClass || "")
    return c === "org.omarchy.agent" || c === "org.omarchy.agent.forge"
  }

  function isForgeClass(winClass) {
    return String(winClass || "") === "org.omarchy.agent.forge"
  }

  function accentForClass(winClass) {
    return overlayRoot.isForgeClass(winClass) ? overlayRoot.forgeAccentHex : overlayRoot.accentHex
  }

  function displayTitle(raw, winClass) {
    var t = String(raw || "").replace(/^\s+|\s+$/g, "")
    t = t.replace(/^(Working…|Working\.\.\.|Waiting for you|Waiting for confirmation|Ready)\s*[|–—-]\s*/i, "")
    if (!t || t.toLowerCase() === "foot")
      return overlayRoot.isForgeClass(winClass) ? "Cursor Forge" : "Cursor CLI"
    return t
  }

  function monitorHasSpecial(mon) {
    var ipc = mon && mon.lastIpcObject
    var sp = ipc && ipc.specialWorkspace
    if (!sp)
      return false
    if (Number(sp.id) !== 0)
      return true
    return String(sp.name || "") !== ""
  }

  function reservedTop(mon) {
    var ipc = mon && mon.lastIpcObject
    var r = ipc && ipc.reserved
    var n = 0
    if (r && r.length >= 2)
      n = Number(r[1]) || 0
    if (n > 0)
      return n
    return overlayRoot.barExclusiveFallback
  }

  function visibleWorkspaceIds() {
    var ids = ({})
    var mons = Hyprland.monitors && Hyprland.monitors.values
    if (!mons)
      return ids
    var fw = Hyprland.focusedWorkspace
    var focusedMonName = fw && fw.monitor ? String(fw.monitor.name || "") : ""
    var focusedId = fw ? Number(fw.id) : 0
    for (var i = 0; i < mons.length; i++) {
      var mon = mons[i]
      if (!mon)
        continue
      if (focusedMonName !== "" && String(mon.name || "") === focusedMonName && focusedId)
        ids[focusedId] = true
      else if (mon.activeWorkspace)
        ids[Number(mon.activeWorkspace.id)] = true
    }
    return ids
  }

  function workspaceIsVisible(ws, mon) {
    if (!ws)
      return false
    return !!overlayRoot.visibleWorkspaceIds()[Number(ws.id)]
  }

  function publishLive(next) {
    var live = ({})
    for (var i = 0; i < next.length; i++)
      live[next[i].address] = true
    overlayRoot.liveVisibleAddresses = live
  }

  function hideAllBars() {
    overlayRoot.liveVisibleAddresses = ({})
  }

  function dropOffscreenWindows() {
    var vis = overlayRoot.visibleWorkspaceIds()
    for (var j = windows.count - 1; j >= 0; j--) {
      var wsId = Number(windows.get(j).wsId) || 0
      if (!vis[wsId])
        windows.remove(j)
    }
  }

  function tileGeomKey(tile) {
    return Math.round(Number(tile.localX) || 0) + ":" + Math.round(Number(tile.localY) || 0) + ":" + Math.round(Number(tile.winW) || 0) + ":" + String(tile.monitorName || "")
  }

  function collect() {
    var out = []
    var workspaces = Hyprland.workspaces.values
    for (var i = 0; i < workspaces.length; i++) {
      var ws = workspaces[i]
      if (ws.id <= 0)
        continue
      var mon = ws.monitor
      if (!overlayRoot.workspaceIsVisible(ws, mon))
        continue
      if (!mon)
        continue
      if (overlayRoot.monitorHasSpecial(mon))
        continue
      var toplevels = ws.toplevels.values
      for (var j = 0; j < toplevels.length; j++) {
        var tl = toplevels[j]
        var ipc = tl.lastIpcObject || {}
        var winClass = String(ipc["class"] || ipc["initialClass"] || "")
        if (!overlayRoot.isAgentClass(winClass))
          continue
        if (ipc.hidden === true)
          continue
        if (ipc.mapped === false)
          continue
        if (ipc.visible === false)
          continue
        var at = ipc.at
        var size = ipc.size
        if (!at || !size || at.length !== 2 || size.length !== 2)
          continue
        if (size[1] < 80)
          continue
        var rawTitle = tl.title || ipc.title || ""
        var address = overlayRoot.canonAddress(tl.address || ipc.address)
        var pid = Number(ipc.pid) || 0
        var y = at[1] - mon.y
        var topPad = overlayRoot.reservedTop(mon)
        var fullscreen = Number(ipc.fullscreen) || 0
        if (fullscreen)
          y = topPad
        else if (y < topPad) {
          // Tiled windows sit below the exclusive zone. A y above it is
          // stale IPC during unmap / workspace switch — adding topPad
          // parked a ghost bar on the wallpaper (and on omarchy-bar).
          if (ipc.floating === true)
            y = topPad
          else
            continue
        }
        var forge = overlayRoot.isForgeClass(winClass)
        var tile = {
          address: address,
          pid: pid,
          wsId: Number(ws.id) || 0,
          title: overlayRoot.displayTitle(rawTitle, winClass),
          titleBusy: overlayRoot.conversationBusy(rawTitle),
          lastQuery: overlayRoot.queryFor(address),
          lastResponseAt: overlayRoot.responseAtFor(address),
          waitingForPrompt: overlayRoot.waitingForPromptFor(address),
          localX: at[0] - mon.x,
          localY: y,
          winW: size[0],
          monitorName: String(mon.name || ""),
          focused: Hyprland.activeToplevel === tl,
          isForge: forge,
          accentHex: overlayRoot.accentForClass(winClass),
          fgHex: overlayRoot.fgHex
        }
        tile.geomKey = overlayRoot.tileGeomKey(tile)
        out.push(tile)
      }
    }
    return out
  }

  function indexOfAddress(address) {
    for (var i = 0; i < windows.count; i++) {
      if (windows.get(i).address === address)
        return i
    }
    return -1
  }

  function syncWindows() {
    var next = overlayRoot.collect()
    overlayRoot.publishLive(next)
    var seen = ({})
    for (var i = 0; i < next.length; i++) {
      var tile = next[i]
      seen[tile.address] = true
      var idx = overlayRoot.indexOfAddress(tile.address)
      if (idx < 0) {
        windows.append(tile)
        continue
      }
      // PanelWindow / layer-shell keeps the mapped size. Changing
      // implicitWidth does not shrink the surface, so the bar stays as a
      // ghost over the sibling tile after a split. Recreate it.
      if (windows.get(idx).geomKey !== tile.geomKey) {
        windows.remove(idx)
        windows.insert(idx, tile)
        continue
      }
      windows.setProperty(idx, "pid", tile.pid)
      windows.setProperty(idx, "wsId", tile.wsId)
      windows.setProperty(idx, "title", tile.title)
      windows.setProperty(idx, "lastQuery", tile.lastQuery)
      windows.setProperty(idx, "lastResponseAt", tile.lastResponseAt)
      windows.setProperty(idx, "waitingForPrompt", tile.waitingForPrompt)
      windows.setProperty(idx, "titleBusy", tile.titleBusy)
      windows.setProperty(idx, "focused", tile.focused)
      windows.setProperty(idx, "isForge", tile.isForge)
      windows.setProperty(idx, "accentHex", tile.accentHex)
      windows.setProperty(idx, "fgHex", tile.fgHex)
    }
    for (var j = windows.count - 1; j >= 0; j--) {
      if (!seen[windows.get(j).address])
        windows.remove(j)
    }
  }

  function pickScreen(name) {
    var screens = Quickshell.screens && Quickshell.screens.values ? Quickshell.screens.values : Quickshell.screens
    if (!screens)
      return null
    var i
    if (name) {
      for (i = 0; i < screens.length; i++) {
        if (screens[i] && screens[i].name === name)
          return screens[i]
      }
    }
    return screens.length > 0 ? screens[0] : null
  }

  function focusAddress(address) {
    if (!address)
      return
    Hyprland.dispatch("focuswindow address:" + address)
  }

  ListModel {
    id: windows
  }

  onAccentHexChanged: {
    for (var i = 0; i < windows.count; i++) {
      var forge = windows.get(i).isForge === true
      windows.setProperty(i, "accentHex", forge ? overlayRoot.forgeAccentHex : overlayRoot.accentHex)
    }
  }
  onFgHexChanged: {
    for (var i = 0; i < windows.count; i++)
      windows.setProperty(i, "fgHex", overlayRoot.fgHex)
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      overlayRoot.hideAllBars()
      overlayRoot.dropOffscreenWindows()
      refreshDebounce.restart()
      geomSettle.arm()
    }
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (/^workspace|focusedmon|activespecial|togglespecial/.test(name)) {
        overlayRoot.hideAllBars()
        overlayRoot.dropOffscreenWindows()
        refreshDebounce.restart()
        geomSettle.arm()
        return
      }
      if (name === "closewindow" || name === "closewindowv2") {
        Hyprland.refreshToplevels()
        overlayRoot.syncWindows()
        return
      }
      if (/window|fullscreen|monitor|float|configreload/.test(name)) {
        refreshDebounce.restart()
        geomSettle.arm()
      }
      if (name === "windowtitle" || name === "windowtitlev2")
        queryDebounce.restart()
    }
  }

  Timer {
    id: refreshDebounce
    interval: 80
    onTriggered: {
      Hyprland.refreshToplevels()
      syncTimer.restart()
    }
  }

  // Split/resize animations finish after openwindow. The first IPC read
  // still has the old size, then nothing fires. Keep syncing until settle.
  Timer {
    id: geomSettle
    interval: 100
    repeat: true
    property int ticksLeft: 0
    function arm() {
      ticksLeft = 12
      running = true
    }
    onTriggered: {
      Hyprland.refreshToplevels()
      overlayRoot.syncWindows()
      ticksLeft--
      if (ticksLeft <= 0)
        stop()
    }
  }

  Timer {
    id: geomWatch
    interval: 250
    running: windows.count > 0
    repeat: true
    onTriggered: {
      Hyprland.refreshToplevels()
      overlayRoot.syncWindows()
    }
  }

  Timer {
    id: syncTimer
    interval: 40
    onTriggered: overlayRoot.syncWindows()
  }

  Timer {
    id: queryDebounce
    interval: 400
    onTriggered: overlayRoot.kickQueries()
  }

  Timer {
    id: clockTick
    interval: 1000
    running: windows.count > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: overlayRoot.nowMs = Date.now()
  }

  Timer {
    id: queryPoll
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: overlayRoot.kickQueries()
  }

  Process {
    id: queryProc
    running: false
    command: ["python3", overlayRoot.lastQueryBin, "--write", overlayRoot.queryFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: overlayRoot.applyQueries(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agent-title last-query", text.trim())
    }
  }

  Component.onCompleted: {
    Hyprland.refreshToplevels()
    syncTimer.restart()
    geomSettle.arm()
  }

  Instantiator {
    model: windows
    active: true
    delegate: PanelWindow {
      id: bar
      required property string address
      required property int wsId
      required property string title
      required property string lastQuery
      required property double lastResponseAt
      required property bool waitingForPrompt
      required property bool titleBusy
      required property int pid
      required property real localX
      required property real localY
      required property real winW
      required property string monitorName
      required property bool focused
      required property bool isForge
      required property string accentHex
      required property string fgHex

      screen: overlayRoot.pickScreen(monitorName)
      // Bind the dict, not a helper: QML will not re-run addressOnScreen()
      // when liveVisibleAddresses is replaced.
      visible: overlayRoot.liveVisibleAddresses[address] === true
      color: "transparent"
      implicitWidth: Math.max(1, Math.round(winW))
      implicitHeight: overlayRoot.barHeight
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "austraz-agent-title"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      anchors {
        top: true
        left: true
      }
      margins {
        top: Math.max(0, Math.round(localY))
        left: Math.max(0, Math.round(localX))
      }

      Rectangle {
        anchors.fill: parent
        color: overlayRoot.fillColor
        border.width: 0
        clip: true

        RowLayout {
          id: row
          anchors.fill: parent
          anchors.leftMargin: overlayRoot.sidePad
          anchors.rightMargin: overlayRoot.sidePad
          spacing: overlayRoot.sidePad

          Text {
            id: titleLabel
            text: title
            textFormat: Text.PlainText
            color: accentHex
            font.family: Omarchy.Style.font.family
            font.pixelSize: Omarchy.Style.font.body
            font.weight: focused ? Font.DemiBold : Font.Normal
            elide: Text.ElideNone
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignLeft
            wrapMode: Text.NoWrap
            Layout.fillWidth: false
            Layout.preferredWidth: implicitWidth
            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
          }

          Text {
            visible: lastQuery.length > 0
            text: lastQuery
            textFormat: Text.PlainText
            color: fgHex
            font.family: Omarchy.Style.font.family
            font.pixelSize: Omarchy.Style.font.body
            font.weight: Font.Normal
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.NoWrap
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            Layout.maximumWidth: Math.max(
              0,
              row.width - titleLabel.implicitWidth - (ageLabel.visible ? ageLabel.implicitWidth : 0) - row.spacing * (ageLabel.visible ? 2 : 1)
            )
          }

          Text {
            id: ageLabel
            visible: lastQuery.length > 0 && lastResponseAt > 0 && (!waitingForPrompt || titleBusy)
            text: "(" + overlayRoot.formatAge(overlayRoot.nowMs - lastResponseAt) + ")"
            textFormat: Text.PlainText
            color: fgHex
            font.family: Omarchy.Style.font.family
            font.pixelSize: Omarchy.Style.font.body
            font.weight: Font.Normal
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.NoWrap
            Layout.fillWidth: false
            Layout.preferredWidth: implicitWidth
            Layout.minimumWidth: implicitWidth
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onClicked: overlayRoot.focusAddress(address)
        }
      }
    }
  }
}
