import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.yassinesawahi.vnc"

  // The helper sits next to this file, wherever the plugin is installed.
  readonly property string scriptPath: decodeURIComponent(Qt.resolvedUrl("vnc.py").toString().replace(/^file:\/\//, ""))
  readonly property bool notifyOnConnect: root.settings.notifyOnConnect === undefined ? true : !!root.settings.notifyOnConnect

  readonly property var glyphs: ({
    idle: String.fromCodePoint(0xF08B9),     // nf-md-remote_desktop
    watched: String.fromCodePoint(0xF13B4),  // nf-md-monitor_eye
    close: String.fromCodePoint(0xF0156),    // nf-md-close
    alert: String.fromCodePoint(0xF0026)     // nf-md-alert
  })

  // Latest `vnc.py status` reading; null until the first one lands.
  property var status: null
  property bool popupOpen: false
  property bool refreshQueued: false

  // "on" or "off" clicked but not yet confirmed by a reading, so the switch
  // flips straight away instead of after wayvnc has come up or gone down.
  property string pending: ""

  readonly property bool running: !!root.status && root.status.running
  readonly property bool serverOn: root.pending !== "" ? root.pending === "on" : root.running
  readonly property var viewers: root.status ? root.status.viewers || [] : []
  readonly property bool watched: root.viewers.length > 0
  readonly property bool noPassword: !!root.status && !root.status.auth

  // People in ~/.config/wayvnc/guests.json, each with a switch in the panel.
  readonly property var guests: root.status ? root.status.guests || [] : []

  // Guest name → "on" or "off" while a click on their switch waits for a
  // reading, so the switch flips straight away.
  property var guestPending: ({})

  function guestAllowed(g) {
    var p = root.guestPending[g.name]
    return p !== undefined ? p === "on" : !!g.allowed
  }

  function findGuest(name) {
    var want = String(name).toLowerCase()
    for (var i = 0; i < root.guests.length; i++)
      if (root.guests[i].name.toLowerCase() === want) return root.guests[i]
    return null
  }

  readonly property var openGuests: root.guests.filter(function(g) { return root.guestAllowed(g) })
  readonly property string openGuestNames: root.openGuests.map(function(g) { return g.name }).join(", ")

  function guestLine(g) {
    var p = root.guestPending[g.name]
    if (p === "on") return root.running ? "Letting in…" : "Turning VNC on and letting in…"
    if (p === "off") return g.viewing > 0 ? "Cutting the session…" : "Shutting out…"
    if (g.viewing > 0) return "Viewing your screen now · switch off to cut the session"
    if (g.allowed) return "Can connect now · " + (g.online ? "PC online" : "PC offline")
    return "Can't connect" + (root.serverOn ? "" : " · switching this on turns VNC on too")
  }

  function viewerName(v) {
    return v.name || v.address || "Someone"
  }

  readonly property string viewerNames: root.viewers.map(root.viewerName).join(", ")

  readonly property string stateLine: {
    if (!root.status) return "Reading…"
    if (root.pending === "on") return "Turning on…"
    if (root.pending === "off") return "Turning off…"
    if (root.watched) return root.viewerNames + (root.viewers.length === 1 ? " is" : " are") + " viewing this screen"
    if (root.running) return "Waiting for viewers on " + root.status.listen
    return "Off · nothing can connect"
  }

  readonly property string tooltipLabel: {
    if (!root.status) return "VNC"
    var s = !root.serverOn ? "VNC is off"
      : root.watched ? root.viewerNames + " viewing your screen"
      : "VNC is on · " + root.status.listen
    if (root.serverOn && root.openGuests.length) s += "\nOpen to " + root.openGuestNames
    return s + "\nMiddle-click to turn it " + (root.serverOn ? "off" : "on")
  }

  readonly property string connectHint: {
    if (!root.status) return ""
    var host = root.status.listen.replace(/:5900$/, "")
    return "Connect a VNC viewer to " + host + (root.status.username ? " as " + root.status.username : "") + "."
      + (root.guests.length ? " Guests connect to " + host + "::" + root.status.guestPort + " with the same login." : "")
      + " Middle-click the bar icon to switch VNC on or off."
  }

  // Shell tooltips and labels may render rich text, and names here come from
  // other devices. Swap angle brackets for look-alikes so no name can carry markup.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/</g, "\u2039").replace(/>/g, "\u203a")
  }

  function refresh() {
    if (readProc.running) root.refreshQueued = true
    else readProc.running = true
  }

  function applyReading(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    root.status = data
    if (!actionProc.running) {
      root.pending = ""
      root.guestPending = ({})
    }
  }

  // Runs `vnc.py <args…>` and re-reads once it finishes. One action at a
  // time; clicks while one is in flight are dropped.
  function run(args) {
    if (actionProc.running) return
    actionProc.command = ["python3", root.scriptPath].concat(args)
    actionProc.running = true
  }

  function setPower(on) {
    if (actionProc.running) return
    root.pending = on ? "on" : "off"
    // Turning VNC off shuts every guest out too.
    if (!on) {
      var p = {}
      root.guests.forEach(function(g) { p[g.name] = "off" })
      root.guestPending = p
    }
    root.run([on ? "on" : "off"])
  }

  function setGuest(name, on) {
    if (actionProc.running) return
    var p = Object.assign({}, root.guestPending)
    p[name] = on ? "on" : "off"
    root.guestPending = p
    // Letting someone in turns VNC on if it's off.
    if (on && !root.serverOn) root.pending = "on"
    root.run(["guest", name, on ? "on" : "off"])
  }

  function togglePower() {
    root.setPower(!root.serverOn)
  }

  function handleEvent(line) {
    var e
    try { e = JSON.parse(line) } catch (err) { return }
    if (e.method === "client-connected" && root.notifyOnConnect && e.params && e.params.address)
      Quickshell.execDetached(["python3", root.scriptPath, "announce", e.params.address])
    root.refresh()
  }

  // Contract KeyboardPanel expects on its `owner`: called when a click
  // outside dismisses the popup, so the `open` binding below stays intact.
  function close() {
    root.popupOpen = false
  }

  function toggle() {
    root.popupOpen = !root.popupOpen
    if (root.popupOpen) root.refresh()
  }

  // The floating bar can mount a hidden second copy of a widget, and an IPC
  // target goes to whichever copy registered last. Only a copy that is on
  // screen takes it, so shortcuts open the panel you can see.
  readonly property bool onScreen: {
    var w = button.QsWindow.window
    return !!w && w.visible && root.visible && root.width > 0 && root.height > 0
  }

  // `omarchy-shell io.github.yassinesawahi.vnc <fn>` — bindable to keys.
  IpcHandler {
    target: "io.github.yassinesawahi.vnc"
    enabled: root.onScreen

    function toggle() { root.toggle() }
    function close() { root.close() }
    function refresh() { root.refresh() }
    function togglePower() { root.togglePower() }
    function turnOn() { root.setPower(true) }
    function turnOff() { root.setPower(false) }
    // `omarchy-shell io.github.yassinesawahi.vnc toggleGuest <name>`
    function toggleGuest(name: string): void {
      var g = root.findGuest(name)
      if (g) root.setGuest(g.name, !root.guestAllowed(g))
    }
  }

  Process {
    id: readProc
    command: ["python3", root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReading(text)
    }
    onExited: {
      if (!root.refreshQueued) return
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  // wayvnc pushes connects and disconnects. wayvncctl waits for it to start
  // and follows it across restarts; pdeathsig takes it down with the shell.
  Process {
    id: eventProc
    running: true
    command: ["setpriv", "--pdeathsig", "TERM", "wayvncctl", "--json", "--wait", "--reconnect", "event-receive"]
    stdout: SplitParser {
      onRead: function(data) { root.handleEvent(data) }
    }
    onExited: eventRestart.restart()
  }

  Timer {
    id: eventRestart
    interval: 5000
    onTriggered: eventProc.running = true
  }

  // Catches a wayvnc started or stopped from a terminal.
  Timer {
    interval: root.popupOpen ? 3000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.plain(root.tooltipLabel)
    fixedWidth: root.vertical ? -1 : glyph.width + button.scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else if (b === Qt.MiddleButton) root.togglePower()
      else root.toggle()
    }

    OpticalGlyph {
      id: glyph
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      text: root.watched ? root.glyphs.watched : root.glyphs.idle
      fontFamily: button.fontFamily
      fontSize: Style.bar.iconFont
      // Lit while someone can see the screen, so it never goes unnoticed, and
      // in the accent colour while a guest is let in.
      color: root.watched || root.noPassword && root.serverOn ? root.bar.urgent
        : root.serverOn && root.openGuests.length ? Commons.Color.accent
        : button.foreground
      opacity: root.serverOn ? 1 : 0.5
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(col.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        readonly property color dim: Qt.darker(root.bar.foreground, 1.4)

        PanelSectionHeader {
          text: "SCREEN SHARING"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // State and the switch.
        Item {
          width: parent.width
          height: Math.max(heroGlyph.implicitHeight, heroText.implicitHeight, powerButton.implicitHeight)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.watched ? root.glyphs.watched : root.glyphs.idle
            color: root.watched ? root.bar.urgent : root.bar.foreground
            opacity: root.serverOn ? 1 : 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title * 1.4
          }

          Column {
            id: heroText
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(10)
            anchors.right: powerButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.serverOn ? "VNC is on" : "VNC is off"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              text: root.stateLine
              textFormat: Text.PlainText
              color: col.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Button {
            id: powerButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.serverOn ? "Turn off" : "Turn on"
            selected: root.serverOn
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.togglePower()
          }
        }

        // Only if the password lines leave ~/.config/wayvnc/config.
        Text {
          visible: root.noPassword
          width: parent.width
          textFormat: Text.PlainText
          text: root.glyphs.alert + "  No password set: anyone on your tailnet can take over this screen. Add one in ~/.config/wayvnc/config."
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          visible: root.guests.length > 0
          text: "GUESTS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // One switch per guest. Indexed rather than bound to the array, so a
        // refresh doesn't rebuild the rows under the pointer.
        Repeater {
          model: root.guests.length

          delegate: Toggle {
            required property int index
            readonly property var guest: root.guests[index] || ({ name: "", allowed: false, viewing: 0, online: false })

            width: col.width
            label: root.plain(guest.name)
            description: root.guestLine(guest)
            checked: root.guestAllowed(guest)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.setGuest(guest.name, !root.guestAllowed(guest))
          }
        }

        PanelSectionHeader {
          visible: root.watched
          text: "VIEWING NOW"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Repeater {
          model: root.viewers

          delegate: Item {
            id: viewerRow
            required property var modelData

            width: col.width
            height: Math.max(viewerText.implicitHeight, dropBtn.height)

            Column {
              id: viewerText
              anchors.left: parent.left
              anchors.right: dropBtn.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.viewerName(viewerRow.modelData)
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                visible: !!viewerRow.modelData.name && !!viewerRow.modelData.address
                width: parent.width
                text: viewerRow.modelData.address
                textFormat: Text.PlainText
                color: col.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: dropBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.glyphs.close
              tooltipText: "Disconnect " + root.plain(root.viewerName(viewerRow.modelData))
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.run(["disconnect", viewerRow.modelData.id])
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.connectHint
          color: col.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
