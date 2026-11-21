import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Radio Malaysia for Omarchy. Playback runs in a detached mpv through the
// bundled bin/radio script, so it survives shell restarts and shows in Omarchy's media
// controls (mpv-mpris). Left click opens the panel; right click stops or
// resumes the last station.
//
// The visualizer reads cava's raw output (48 frequency bands, 0-100, 30 fps).
// cava listens to the default output monitor, so it shows whatever is playing
// on the speakers; it only runs while the radio plays and something shows it.
Panel {
  id: root
  moduleName: "pdoc81.radio-malaysia"
  ipcTarget: "radio-malaysia"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showStation: setting("showStation", true) === true
  readonly property bool barVisualizer: setting("barVisualizer", true) === true

  property var stations: []
  property var groups: []
  property bool playing: false
  property bool buffering: false
  property string stationId: ""
  property string trackTitle: ""
  property string codec: ""
  property int bitrate: 0
  property int samplerate: 0
  property int cacheSecs: -1
  property int volume: 70
  property bool volumeDragging: false

  property var health: ({})
  property var logoFiles: ({})       // id -> file URL of the cached logo
  property bool cavaMissing: false
  readonly property string script: Qt.resolvedUrl("bin/radio").toString().replace("file://", "")
  property var favs: []
  property int healthChecked: 0
  readonly property int liveCount: countHealth(1)
  readonly property int deadCount: countHealth(0)

  // Visualizer
  readonly property int bands: 48
  property var levels: []
  property string vizMode: "bars"   // bars | wave | spectrogram; saved by `radio mode`
  property bool vizModeLoaded: false
  readonly property bool vizWanted: root.playing && !root.buffering && (root.opened || root.barVisualizer)

  readonly property string stationName: nameOf(stationId)
  readonly property string iconRadio: String.fromCodePoint(0xF0439)  // radio

  // ---- Colour: rainbow across the spectrum, red bass to violet treble.
  function bandColor(i, n, light) {
    return Qt.hsla(0.0 + 0.82 * i / Math.max(1, n - 1), 0.85, light === undefined ? 0.6 : light, 1.0)
  }
  // Heat map for the spectrogram: black, indigo, magenta, orange, yellow, white.
  readonly property var heatStops: [
    [0.00, 0.02, 0.02, 0.06], [0.18, 0.20, 0.05, 0.45], [0.38, 0.65, 0.10, 0.60],
    [0.58, 0.95, 0.30, 0.25], [0.78, 1.00, 0.70, 0.10], [1.00, 1.00, 1.00, 0.85]]
  property var heatLut: buildHeat()
  function buildHeat() {
    var lut = []
    for (var k = 0; k <= 100; k++) {
      var t = k / 100, s = heatStops
      for (var j = 1; j < s.length; j++) {
        if (t <= s[j][0]) {
          var f = (t - s[j - 1][0]) / (s[j][0] - s[j - 1][0])
          lut.push(Qt.rgba(s[j - 1][1] + f * (s[j][1] - s[j - 1][1]),
                           s[j - 1][2] + f * (s[j][2] - s[j - 1][2]),
                           s[j - 1][3] + f * (s[j][3] - s[j - 1][3]), 1))
          break
        }
      }
    }
    return lut
  }

  function nameOf(id) {
    for (var i = 0; i < stations.length; i++) if (stations[i].id === id) return stations[i].name
    return ""
  }

  function countHealth(v) {
    var n = 0
    for (var k in health) if (health[k] === v) n++
    return n
  }

  // stations.json is our own file, but keep it bounded and well-formed anyway.
  function loadStations(raw) {
    var list = []
    var seenGroups = []
    try {
      var data = JSON.parse(raw)
      if (!Array.isArray(data)) return
      for (var i = 0; i < data.length && list.length < 200; i++) {
        var s = data[i]
        if (!s || typeof s.id !== "string" || !/^[a-z0-9]{1,32}$/.test(s.id)) continue
        if (typeof s.name !== "string" || typeof s.group !== "string") continue
        var st = { id: s.id, name: s.name.slice(0, 40), group: s.group.slice(0, 24) }
        list.push(st)
        if (seenGroups.indexOf(st.group) < 0) seenGroups.push(st.group)
      }
    } catch (e) {
      return
    }
    root.stations = list
    root.groups = seenGroups
  }

  // Dropdown rows: name, then group and last health check (both searchable).
  // Favourites first (in the order they were starred), then the rest as listed.
  readonly property var orderedStations: {
    var f = root.favs, favList = [], rest = []
    for (var i = 0; i < f.length; i++) {
      for (var j = 0; j < root.stations.length; j++) if (root.stations[j].id === f[i]) favList.push(root.stations[j])
    }
    for (var k = 0; k < root.stations.length; k++) if (f.indexOf(root.stations[k].id) < 0) rest.push(root.stations[k])
    return favList.concat(rest)
  }

  readonly property var stationOptions: {
    var h = root.health, f = root.favs
    return root.orderedStations.map(function(st) {
      var state = h[st.id]
      var fav = f.indexOf(st.id) >= 0
      return { value: st.id, label: st.name, logo: root.logoFiles[st.id] || "", fav: fav,
               description: fav ? strings.t("favourite") + "  \u00B7  " + st.group : st.group,
               health: state === 1 || state === 0 ? state : -1 }
    })
  }

  function toggleFav(id) {
    if (!/^[a-z0-9]{1,32}$/.test(id)) return
    var f = root.favs.slice(), i = f.indexOf(id)
    if (i >= 0) f.splice(i, 1); else f.push(id)
    root.favs = f
    run(["fav", id])
  }

  function step(dir) {
    var list = root.orderedStations, n = list.length
    if (n === 0) return
    var i = -1
    for (var k = 0; k < n; k++) if (list[k].id === root.stationId) i = k
    var j = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n
    root.play(list[j].id)
  }

  function stationsIn(group) {
    return root.stations.filter(function(s) { return s.group === group })
  }

  function num(v, max) {
    return /^[0-9]{1,9}$/.test(v) ? Math.min(max, Number(v)) : 0
  }

  function parseStatus(raw) {
    var lines = String(raw).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      var k = lines[i].slice(0, eq), v = lines[i].slice(eq + 1)
      if (k === "favs") root.favs = /^[a-z0-9,]{0,4000}$/.test(v) ? v.split(",").filter(function(x) { return x !== "" }) : []
      else if (k === "mode") { if (!root.vizModeLoaded && /^(bars|wave|spectrogram)$/.test(v)) root.vizMode = v; root.vizModeLoaded = true }
      else if (k === "playing") root.playing = v === "1"
      else if (k === "buffering") root.buffering = v === "1"
      else if (k === "station" && /^[a-z0-9]{0,32}$/.test(v)) root.stationId = v
      else if (k === "volume" && /^[0-9]{1,3}$/.test(v)) { if (!root.volumeDragging) root.volume = Math.min(100, Number(v)) }
      else if (k === "codec") root.codec = /^[A-Za-z0-9_-]{0,16}$/.test(v) ? v : ""
      else if (k === "bitrate") root.bitrate = num(v, 10000000)
      else if (k === "samplerate") root.samplerate = num(v, 400000)
      else if (k === "cache") root.cacheSecs = v === "" ? -1 : num(v, 3600)
      else if (k === "title") root.trackTitle = v.slice(0, 120)
    }
  }

  function parseHealth(raw) {
    var lines = String(raw).split("\n")
    var map = {}
    for (var i = 0; i < lines.length && i < 400; i++) {
      var m = /^([a-z0-9]{1,32})=([01])$/.exec(lines[i])
      if (m) { map[m[1]] = Number(m[2]); continue }
      var c = /^checked=([0-9]{1,12})$/.exec(lines[i])
      if (c) root.healthChecked = Number(c[1])
    }
    root.health = map
  }

  // One cava frame: "12;34;...;" with 48 values in 0-100.
  function pushFrame(line) {
    var parts = String(line).split(";")
    if (parts.length < root.bands) return
    var out = new Array(root.bands)
    for (var i = 0; i < root.bands; i++) {
      var n = parseInt(parts[i], 10)
      out[i] = isNaN(n) ? 0 : Math.max(0, Math.min(100, n))
    }
    root.levels = out
  }

  readonly property string techLine: {
    if (!root.playing) return ""
    var parts = []
    if (root.codec !== "") parts.push(root.codec.toUpperCase())
    if (root.bitrate > 0) parts.push(Commons.I18n.formatNumber(Math.round(root.bitrate / 1000)) + " kbps")
    if (root.samplerate > 0) parts.push(Commons.I18n.formatNumber(root.samplerate / 1000, root.samplerate % 1000 ? 1 : 0) + " kHz")
    if (root.cacheSecs >= 0) parts.push(strings.t("buffer").arg(Commons.I18n.formatNumber(root.cacheSecs)))
    return parts.join("  ·  ")
  }

  readonly property string healthLine: {
    if (healthProc.running) return strings.t("checking")
    if (root.healthChecked === 0) return ""
    var at = new Date(root.healthChecked * 1000)
    return strings.t("healthSummary")
      .arg(Commons.I18n.formatNumber(root.liveCount))
      .arg(Commons.I18n.formatNumber(root.liveCount + root.deadCount))
      .arg(at.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm"))
  }

  function run(args) {
    if (cmdProc.running) { pending = args; return }
    cmdProc.command = [root.script].concat(args)
    cmdProc.running = true
  }
  property var pending: null
  property int pickerRequests: 0

  function play(id) {
    root.stationId = id; root.playing = true; root.buffering = true
    root.trackTitle = ""; root.codec = ""; root.bitrate = 0; root.samplerate = 0; root.cacheSecs = -1
    run(["play", id])
  }
  function stop() { root.playing = false; root.trackTitle = ""; root.levels = []; run(["stop"]) }
  function toggle_() {
    if (root.playing) stop()
    else if (root.stationId !== "") play(root.stationId)
  }
  function setVizMode(m) {
    if (["bars", "wave", "spectrogram"].indexOf(m) < 0 || m === root.vizMode) return
    root.vizMode = m
    root.vizModeLoaded = true
    run(["mode", m])
  }
  function refresh() { if (!statusProc.running && !cmdProc.running) statusProc.running = true }
  function checkHealth(force) {
    if (healthProc.running) return
    healthProc.command = force ? [root.script, "check"] : [root.script, "check", "--if-stale", "1800"]
    healthProc.running = true
  }

  ShellIpc {
    target: "radio-malaysia"
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function playPause() { root.toggle_() }
    function stop() { root.stop() }
    function mode(m: string) { root.setVizMode(m) }
    function fav(id: string) { root.toggleFav(id) }
    function openPicker() { root.open(); root.pickerRequests++ }
  }

  FileView {
    path: Qt.resolvedUrl("stations.json").toString().replace("file://", "")
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.loadStations(text())
  }

  Process {
    id: statusProc
    command: [root.script, "status"]
    running: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseStatus(text) }
  }

  Process {
    id: cmdProc
    onExited: {
      if (root.pending) {
        var next = root.pending
        root.pending = null
        root.run(next)
      } else {
        statusProc.running = true
      }
    }
  }

  // Logos: downloaded once into ~/.cache/radio-malaysia/logos by the script.
  function parseLogos(raw) {
    var lines = String(raw).split("\n"), dir = "", ids = []
    for (var i = 0; i < lines.length && i < 400; i++) {
      var d = /^dir=(\/[^\n]{1,300})$/.exec(lines[i])
      if (d) { dir = d[1]; continue }
      var m = /^([a-z0-9]{1,32})=1$/.exec(lines[i])
      if (m) ids.push(m[1])
    }
    if (dir === "" || dir.indexOf("..") >= 0) return
    var map = {}
    for (var k = 0; k < ids.length; k++) map[ids[k]] = "file://" + dir + "/" + ids[k] + ".png"
    root.logoFiles = map
  }

  Process {
    id: logosProc
    command: [root.script, "logos"]
    running: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseLogos(text) }
  }

  Process {
    id: cavaCheck
    command: ["sh", "-c", "command -v cava"]
    running: true
    onExited: function(code) { root.cavaMissing = code !== 0 }
  }

  Process {
    id: healthProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseHealth(text) }
  }

  Process {
    id: healthRead
    command: [root.script, "health"]
    running: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseHealth(text) }
  }

  Process {
    id: cava
    command: ["cava", "-p", Qt.resolvedUrl("cava.conf").toString().replace("file://", "")]
    running: root.vizWanted && !root.cavaMissing
    stdout: SplitParser { onRead: function(data) { root.pushFrame(data) } }
    onRunningChanged: if (!running) root.levels = []
  }

  // Poll faster while the panel is open or a stream is connecting.
  Timer {
    interval: root.opened || root.buffering ? 2000 : 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) { refresh(); checkHealth(false); if (!logosProc.running) logosProc.running = true }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconRadio
    iconComponent: root.playing && root.barVisualizer ? miniViz : null
    labelText: root.showStation && root.playing && !vertical ? root.stationName : ""
    slotSize: Style.bar.iconSlot * (labelText === "" ? 1 : 1.4 + labelText.length * 0.42)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle_()
      else root.toggle()
    }
  }

  // Five rainbow bars in place of the bar icon while playing.
  Component {
    id: miniViz
    Canvas {
      id: mini
      implicitWidth: Style.bar.iconSize
      implicitHeight: Style.bar.iconSize
      property var lv: root.levels
      onLvChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        var n = 5, gap = Math.max(1, Math.round(width * 0.08))
        var bw = (width - gap * (n - 1)) / n
        var per = Math.floor(root.bands / n)
        for (var i = 0; i < n; i++) {
          var sum = 0
          for (var j = 0; j < per; j++) sum += (lv[i * per + j] || 0)
          var v = Math.max(0.12, Math.min(1, sum / per / 70))
          var h = Math.max(2, v * height)
          ctx.fillStyle = root.bandColor(i, n, 0.62)
          ctx.fillRect(i * (bw + gap), height - h, bw, h)
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: root.playing && root.stationName !== "" ? root.stationName : strings.t("title")
          meta: !root.playing ? strings.t("off").toUpperCase()
            : (root.buffering ? strings.t("connecting").toUpperCase() : strings.t("onAir").toUpperCase())
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.playing ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.iconRadio
              color: root.playing ? root.bandColor(0, 1, 0.62) : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.playing
              busy: cmdProc.running
              enabled: root.playing || root.stationId !== ""
              foreground: root.foreground
              onToggled: root.toggle_()
            }
          }
        }

        Text {
          width: parent.width
          visible: root.playing && root.trackTitle !== ""
          textFormat: Text.PlainText
          text: "\u266A  " + root.trackTitle
          elide: Text.ElideRight
          color: root.bandColor(0, 1, 0.7)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        // ---- Visualizer
        Rectangle {
          id: vizFrame
          width: parent.width
          height: Style.space(110)
          radius: Style.cornerRadius > 0 ? Style.space(8) : 0
          color: Qt.rgba(0, 0, 0, 0.35)
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          clip: true

          Canvas {
            id: spectrum
            anchors.fill: parent
            anchors.margins: Style.space(8)
            visible: root.vizMode !== "spectrogram"
            property var lv: root.levels
            property var peaks: []
            onLvChanged: if (visible) requestPaint()
            onVisibleChanged: if (visible) requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var n = root.bands
              if (root.vizMode === "bars") {
                var gap = 2, bw = (width - gap * (n - 1)) / n
                var pk = peaks.length === n ? peaks : new Array(n).fill(0)
                for (var i = 0; i < n; i++) {
                  var v = (lv[i] || 0) / 100
                  var h = Math.max(2, v * height)
                  var x = i * (bw + gap)
                  var g = ctx.createLinearGradient(0, height, 0, height - h)
                  g.addColorStop(0, root.bandColor(i, n, 0.45))
                  g.addColorStop(1, root.bandColor(i, n, 0.72))
                  ctx.fillStyle = g
                  ctx.fillRect(x, height - h, bw, h)
                  pk[i] = Math.max(v, (pk[i] || 0) - 0.012)
                  ctx.fillStyle = root.bandColor(i, n, 0.85)
                  ctx.fillRect(x, height - pk[i] * height - 3, bw, 2)
                }
                peaks = pk
              } else {
                // Wave: the spectrum as a mirrored, smoothed ribbon around the centre line.
                var mid = height / 2
                var grad = ctx.createLinearGradient(0, 0, width, 0)
                for (var s = 0; s <= 6; s++) grad.addColorStop(s / 6, root.bandColor(s, 7, 0.6))
                var pts = []
                for (var k = 0; k < n; k++) pts.push([k / (n - 1) * width, (lv[k] || 0) / 100 * (mid - 2)])
                for (var side = -1; side <= 1; side += 2) {
                  ctx.beginPath()
                  ctx.moveTo(0, mid)
                  for (var p = 0; p < n - 1; p++) {
                    var cx = (pts[p][0] + pts[p + 1][0]) / 2
                    var cy = mid + side * (pts[p][1] + pts[p + 1][1]) / 2
                    ctx.quadraticCurveTo(pts[p][0], mid + side * pts[p][1], cx, cy)
                  }
                  ctx.lineTo(width, mid)
                  ctx.closePath()
                  ctx.globalAlpha = 0.45
                  ctx.fillStyle = grad
                  ctx.fill()
                  ctx.globalAlpha = 1.0
                  ctx.lineWidth = 2
                  ctx.strokeStyle = grad
                  ctx.stroke()
                }
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.25)
                ctx.fillRect(0, mid - 0.5, width, 1)
              }
            }
          }

          // Spectrogram: time runs right to left, bass at the bottom.
          Canvas {
            id: gram
            anchors.fill: parent
            anchors.margins: Style.space(8)
            visible: root.vizMode === "spectrogram"
            readonly property int rows: 32
            readonly property int colW: 3
            readonly property int cols: Math.max(1, Math.floor(width / colW))
            property var history: []
            property var lv: root.levels
            onLvChanged: {
              if (!root.vizWanted) { history = []; if (visible) requestPaint(); return }
              var step = root.bands / rows, col = new Array(rows)
              for (var r = 0; r < rows; r++) {
                var a = Math.floor(r * step), b = Math.max(a + 1, Math.floor((r + 1) * step)), m = 0
                for (var i = a; i < b; i++) m = Math.max(m, lv[i] || 0)
                col[r] = m
              }
              var h = history
              h.push(col)
              if (h.length > cols) h.splice(0, h.length - cols)
              history = h
              if (visible) requestPaint()
            }
            onPaint: {
              var ctx = getContext("2d")
              ctx.fillStyle = root.heatLut[0]
              ctx.fillRect(0, 0, width, height)
              var rh = height / rows
              var x0 = width - history.length * colW
              for (var c = 0; c < history.length; c++) {
                var col = history[c]
                for (var r = 0; r < rows; r++) {
                  var v = col[r]
                  if (v < 3) continue
                  ctx.fillStyle = root.heatLut[v]
                  ctx.fillRect(x0 + c * colW, height - (r + 1) * rh, colW, Math.ceil(rh))
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: !root.playing || root.levels.length === 0
            textFormat: Text.PlainText
            text: root.cavaMissing ? strings.t("noCava") : (!root.playing ? strings.t("vizIdle") : strings.t("vizWaiting"))
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Row {
          id: modeRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 2) / 3
          Repeater {
            model: ["bars", "wave", "spectrogram"]
            Button {
              required property string modelData
              width: modeRow.cellWidth
              text: strings.t("mode." + modelData)
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              active: root.vizMode === modelData
              onClicked: root.setVizMode(modelData)
            }
          }
        }

        // ---- Stream status
        Text {
          width: parent.width
          visible: root.techLine !== ""
          textFormat: Text.PlainText
          text: root.techLine
          elide: Text.ElideRight
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            id: volLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("volume")
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          PanelSlider {
            id: volSlider
            bar: root.bar
            width: parent.width - volLabel.width - volPct.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.volume
            onDraggingChanged: root.volumeDragging = dragging
            onReleased: function(v) { root.volume = Math.round(v); root.run(["volume", String(root.volume)]) }
          }
          Text {
            id: volPct
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
            text: Commons.I18n.formatNumber(Math.round(volSlider.dragging ? volSlider.liveValue : root.volume)) + "%"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- Station health
        Item {
          width: parent.width
          implicitHeight: Math.max(healthText.implicitHeight, checkBtn.implicitHeight)

          Row {
            id: healthText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 8; height: 8; radius: 4
              color: healthProc.running ? "#f5c542" : (root.deadCount > 0 ? "#f5a142" : "#4cd964")
              visible: root.healthChecked > 0 || healthProc.running
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.healthLine
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Button {
            id: checkBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("checkNow")
            fontSize: Style.font.caption
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: !healthProc.running
            onClicked: root.checkHealth(true)
          }
        }

        // ---- Station picker: searchable dropdown with previous / next.
        Row {
          id: pickRow
          width: parent.width
          spacing: Style.space(6)

          Button {
            id: prevBtn
            width: Style.spacing.controlHeight
            height: picker.rowHeight
            text: "\u2039"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.stations.length > 0
            onClicked: root.step(-1)
          }

          StationDropdown {
            id: picker
            width: pickRow.width - prevBtn.width - nextBtn.width - pickRow.spacing * 2
            showLabel: false
            fontFamily: root.fontFamily
            foreground: root.foreground
            placeholderText: strings.t("search")
            triggerLabel: root.stationId === "" ? strings.t("pick") : ""
            value: root.stationId
            options: root.stationOptions
            liveText: strings.t("liveTag")
            onFavoriteToggled: function(v) { root.toggleFav(v) }
            downText: strings.t("downTag")
            Connections {
              target: root
              function onPickerRequestsChanged() { Qt.callLater(picker.open) }
            }
            onChanged: function(v) {
              root.play(v)
              // The dropdown assigns `value` itself on pick; re-link it so ‹ › keep it in sync.
              picker.value = Qt.binding(function() { return root.stationId })
            }
          }

          Button {
            id: nextBtn
            width: Style.spacing.controlHeight
            height: picker.rowHeight
            text: "\u203A"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.stations.length > 0
            onClicked: root.step(1)
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: strings.t("hint") + "\n" + strings.t("credit")
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
