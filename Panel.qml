import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Paperclip bar widget: one icon that says whether your agents are moving
// and whether anything is waiting for you, and one panel that lets you act on
// it without opening the web app.
Panel {
  id: root
  moduleName: "sceny.paperclipai"
  ipcTarget: "paperclip"
  manageIpc: false

  // The plugin lives wherever it was installed, so its scripts are found
  // relative to this file rather than through $OMARCHY_PATH.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color panelBackground: Color.popups ? Color.popups.background : Color.background
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Quiet means the zzz is on the icon and the bubble is gone. The panel
  // itself still lists everything: a snooze silences interruptions, it never
  // hides the inbox.
  readonly property bool asleep: service.quiet.quiet

  // Identical rows collapse into one, so a watchdog looping every fifteen
  // minutes reads as "Kai run failed ×115" rather than as a hundred rows.
  // The summary cards filter what the lists show, nothing else: the inbox
  // setting, the bar's count and the cards' own numbers stay as they were.
  property string cardFilter: ""
  readonly property string activeFilter: Model.activeTileFilter(service.report, cardFilter)
  onActiveFilterChanged: rowIndex = 0

  readonly property var needGroups: Model.groupRows(
    Model.filterNeedRows(service.report ? service.report.needs : [], activeFilter))
  readonly property int needsCap: 6
  property bool showAllRows: false
  readonly property var needs: showAllRows ? needGroups : needGroups.slice(0, needsCap)
  readonly property var moving: Model.filterMovingRows(service.report ? service.report.moving : [], activeFilter)
  readonly property var action: Model.primaryAction(service.report)
  readonly property int rowCount: needs.length + moving.length
  readonly property var tiles: Model.statTiles(service.report)
  // How many open rows this list does not reach. Named, never hidden: a list
  // that stops without saying so is how a number stops matching its list.
  readonly property int moreWaiting: Model.moreWaiting(service.report, listedRows(needs), activeFilter)
  // The probe's own complaints, shown under the button that acts on them.
  readonly property var problems: service.problems

  // The probe's summary, then the Paperclip version as quiet trailing text.
  readonly property string summaryLine: {
    var text = service.report ? service.report.summary : "Checking…"
    var version = service.report && service.report.health ? String(service.report.health.version || "") : ""
    return version !== "" ? text + " · v" + version : text
  }

  property bool cursorActive: false
  property int rowIndex: 0

  // `Retry all` arms on the first press and runs on the second, naming the
  // count and the company in between. One keypress must not be able to start
  // twenty agent runs.
  property bool retryArmed: false

  function listedRows(groups) {
    var total = 0
    for (var i = 0; i < (groups || []).length; i++) total += Number(groups[i].count || 1)
    return total
  }

  readonly property string inboxOwner: {
    var companies = service.report && service.report.companies ? service.report.companies : []
    return companies.length === 1 ? String(companies[0].name || "") : ""
  }

  function askRetryAll() {
    if (service.retryableCount === 0) {
      // The service already knows how to say this, and how to clear it again.
      service.retryAll()
      return
    }
    if (!retryArmed) {
      retryArmed = true
      retryArmTimer.restart()
      return
    }
    retryArmed = false
    retryArmTimer.stop()
    service.retryAll()
  }

  Timer {
    id: retryArmTimer
    interval: 6000
    repeat: false
    onTriggered: root.retryArmed = false
  }

  // One table decides what every surface paints in, so the hero, the tiles,
  // the rows and the bar never disagree about what "needs you" looks like.
  // The tones themselves come from Model.stateTone().
  function toneColor(tone) {
    if (tone === "alarm" || tone === "attention") return urgent
    // `waiting` is a long inbox with nothing urgent in it. A hundred stale
    // rows are worth a number, not a colour.
    if (tone === "working" || tone === "waiting") return foreground
    return dim
  }

  // What the bar bubble paints in: the tone of the rows the panel lists.
  readonly property string badgeTone: Model.badgeTone(service.report)
  readonly property bool badgeUrgent: badgeTone === "alarm" || badgeTone === "attention"

  // The mark itself only has two colors: urgent while something is wrong or
  // waiting on a person, plain the rest of the time. Idle dimming is the bar
  // button's job, not the mark's.
  function markColor(tone) {
    if (asleep) return foreground
    return (tone === "alarm" || tone === "attention") ? urgent : foreground
  }

  // ------------------------------------------------------------- motion
  //
  // Every transition in this file is gated on `motion`, which is the
  // plugin's `animations` setting. Off keeps the layout and the colors and
  // only removes the movement.
  //
  // The panel builds itself in one short cascade when it opens: each block
  // fades up a beat after the one above it. `revealAt()` cuts one shared
  // 0..1 progress into those per-block windows, so the whole cascade is
  // driven by a single animation instead of eight.
  readonly property bool motion: service.animations
  property real reveal: 1
  readonly property real revealStagger: 0.085
  readonly property real revealSpan: 0.55

  function revealAt(step) {
    if (!motion) return 1
    var t = (reveal - step * revealStagger) / revealSpan
    return t < 0 ? 0 : (t > 1 ? 1 : t)
  }

  function revealLift(step) {
    return (1 - revealAt(step)) * Style.space(10)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    service.panelOpen = opened
    if (opened) {
      cursorActive = false
      rowIndex = 0
      showAllRows = false
      cardFilter = ""
      retryArmed = false
      service.stopArmed = false
      service.clearNotes()
      if (panelFlick) panelFlick.contentY = 0
      service.refresh()
      reveal = 0
      if (root.motion) revealAnimation.restart()
      else reveal = 1
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "reveal"
    from: 0
    to: 1
    duration: 560
    easing.type: Easing.OutCubic
  }

  function rowAt(index) {
    if (index < 0) return null
    if (index < needs.length) return needs[index]
    var moved = index - needs.length
    return moved < moving.length ? moving[moved] : null
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || rowCount === 0) return
    rowIndex = Math.max(0, Math.min(rowCount - 1, rowIndex + dy))
    scrollCursorIntoView()
  }

  function setRowCursor(index) {
    cursorActive = true
    rowIndex = index
  }

  function activateCursor() {
    var row = rowAt(rowIndex)
    if (row && row.url) service.openUrl(row.url)
    else if (action) service.run(action.id)
  }

  function scrollCursorIntoView() {
    if (!panelFlick) return
    var items = rowIndex < needs.length
      ? (needsColumn ? needsColumn.children : [])
      : (movingColumn ? movingColumn.children : [])
    var localIndex = rowIndex < needs.length ? rowIndex : rowIndex - needs.length
    if (localIndex < 0 || localIndex >= items.length) return
    var item = items[localIndex]
    if (!item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function filterCard(key: string): string {
      root.cardFilter = Model.toggleTileFilter(root.activeFilter, key)
      return root.activeFilter === "" ? "none" : root.activeFilter
    }
    function status(): string { return service.instanceState + " — " + (service.report ? service.report.summary : "") }
    function board(): string { service.openBoard(); return "ok" }
    function doctor(): string { service.runDoctor(); return "ok" }
    function serviceState(): string { return service.serviceControl.state + (service.stopArmed ? " (confirm)" : "") }
    function startService(): string { return service.startService() }
    function stopService(): string { return service.stopService() }
    function toggleService(): string { return service.toggleService() }
    function snooze(): string { service.toggleSnooze(false); return service.quiet.mode }
    function snoozeUntilMorning(): string { service.toggleSnooze(true); return service.quiet.mode }
    function focus(): string { service.toggleFocus(); return service.quiet.mode }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: Model.tooltipText(service.report, service.quiet)
    active: !root.asleep && (service.attention > 0 || service.trouble)
    dimmed: root.asleep || service.instanceState === "idle" || service.instanceState === "unknown"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) service.openBoard()
      else if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }

    // The bar wears the brand mark, not a font glyph: the same paperclip the
    // panel and the app launcher show. State is carried by its color and its
    // motion — urgent when a person is needed, a light running along the wire
    // while agents work — so the shape itself never changes.
    iconComponent: Component {
      // The loader resizes its root to the whole icon canvas, so the mark sits
      // in a root of its own and keeps the size it asks for.
      Item {
        PaperclipMark {
          // Sized from the stock bar icon font, like the glyph icons beside
          // it, so the mark is as tall as they are rather than as tall as
          // the whole icon canvas.
          anchors.centerIn: parent
          width: Style.bar.iconFont * 0.9
          height: Style.bar.iconFont * 0.9
          thickness: 24
          color: root.markColor(service.tone)
          motion: root.motion
          working: !root.asleep && service.tone === "working"
          attention: !root.asleep && (service.tone === "attention" || service.tone === "alarm")

          Behavior on color {
            enabled: root.motion
            ColorAnimation { duration: 220; easing.type: Easing.OutCubic }
          }
        }
      }
    }

    // The icon canvas the stock widgets draw in. The bubble and the zzz hang
    // from its top edge, so they never rise above the icons beside them; they
    // reach a little past its right edge, into the button's own padding, so
    // they sit beside the narrow mark instead of on top of it.
    Item {
      id: iconBox
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
    }

    // While the plugin is quiet the bubble gives way to a zzz in the same
    // corner: the same spot, so the eye finds it where it looked for the
    // count, and a glyph rather than a colour, so it reads without one.
    Text {
      id: sleepMark
      visible: root.asleep
      textFormat: Text.PlainText
      anchors.right: iconBox.right
      anchors.rightMargin: -Style.space(4)
      anchors.top: iconBox.top
      text: Model.GLYPH_SLEEP
      color: root.bar ? root.bar.barForeground : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, Style.font.caption)
      renderType: Text.NativeRendering
    }

    // The bubble: a count when people are waited on, a dot when agents are
    // simply busy, nothing at all when there is nothing to say.
    Rectangle {
      id: bubble
      visible: !root.asleep && (badge.text !== "" || dotVisible)
      readonly property bool dotVisible: badge.text === "" &&
        (service.working > 0 || service.attention > 0 || service.trouble)
      width: badge.text !== "" ? Math.max(Style.space(10), badge.implicitWidth + Style.space(4)) : Style.space(5)
      height: badge.text !== "" ? Style.space(10) : Style.space(5)
      radius: height / 2
      color: root.badgeUrgent ? root.urgent : (root.bar ? root.bar.barForeground : root.foreground)
      anchors.right: iconBox.right
      anchors.rightMargin: -Style.space(4)
      anchors.top: iconBox.top

      Behavior on color {
        enabled: root.motion
        ColorAnimation { duration: 220; easing.type: Easing.OutCubic }
      }
      Behavior on width {
        enabled: root.motion
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }
      Behavior on height {
        enabled: root.motion
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }

      Text {
        id: badge
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: service.showCount ? Model.badgeText(service.report) : ""
        color: root.bar ? root.bar.background : root.panelBackground
        font.family: root.fontFamily
        font.pixelSize: Math.max(7, Style.font.caption - 2)
        font.bold: true
        renderType: Text.NativeRendering

        // A new number is worth one glance, so the bubble flicks out and
        // settles instead of swapping digits silently.
        onTextChanged: if (root.motion && badge.text !== "") countPop.restart()
      }

      SequentialAnimation {
        id: countPop
        NumberAnimation { target: bubble; property: "scale"; to: 1.4; duration: 110; easing.type: Easing.OutCubic }
        NumberAnimation { target: bubble; property: "scale"; to: 1.0; duration: 260; easing.type: Easing.OutBack }
      }

      // Agents working, nobody waiting: breathe. Stopping the loop leaves the
      // opacity wherever the last frame put it, so settle it by hand.
      readonly property bool breathing: visible && root.motion &&
        service.working > 0 && service.attention === 0
      onBreathingChanged: if (!breathing) settleBubble.restart()

      NumberAnimation {
        id: settleBubble
        target: bubble
        property: "opacity"
        to: 1.0
        duration: 240
        easing.type: Easing.OutCubic
      }

      SequentialAnimation {
        running: bubble.breathing
        loops: Animation.Infinite
        NumberAnimation { target: bubble; property: "opacity"; to: 0.35; duration: 900; easing.type: Easing.InOutQuad }
        NumberAnimation { target: bubble; property: "opacity"; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(12) + footerBlock.implicitHeight, Style.space(580))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // `x` never reaches onTextKey — the key catcher claims it as delete,
      // which is exactly what clearing a row is.
      onDeleteRequested: service.dismissRow(root.rowAt(root.rowIndex))
      onTextKey: function(key) {
        var k = String(key)
        var lower = k.toLowerCase()
        if (lower === "r") service.refresh()
        else if (lower === "o") service.openBoard()
        else if (lower === "d") service.runDoctor()
        else if (lower === "v") service.toggleService()
        else if (lower === "n") service.cycleNotifications()
        else if (lower === "z") service.toggleSnooze(k === "Z")
        else if (lower === "p") service.toggleFocus()
        else if (lower === "a") root.showAllRows = !root.showAllRows
        else if (lower === "f") service.cycleInboxFilter()
        else if (k === "T") root.askRetryAll()
        else if (k === "t") service.retryRow(root.rowAt(root.rowIndex))
        // Set-up and snooze never contend: an instance that is not installed
        // has no inbox to snooze. Shift+S pushes the row to 09:00 tomorrow.
        else if (lower === "s") {
          if (service.instanceState === "not-installed") service.runSetup()
          else service.snoozeRow(root.rowAt(root.rowIndex), k === "S")
        }
      }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footerBlock.top
        anchors.bottomMargin: Style.space(12)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelHero {
              id: hero
              width: parent.width
              title: "Paperclip"
              meta: service.actionStatus !== "" ? service.actionStatus : root.summaryLine
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: service.trouble ? 0.6 : 1.0
              opacity: root.revealAt(0)
              transform: Translate { y: root.revealLift(0) }
              iconComponent: Component {
                PaperclipMark {
                  implicitWidth: Style.space(30)
                  implicitHeight: Style.space(30)
                  thickness: 20
                  color: root.markColor(service.tone)
                  motion: root.motion && root.opened
                  working: !root.asleep && service.tone === "working"
                  attention: !root.asleep && (service.tone === "attention" || service.tone === "alarm")

                  Behavior on color {
                    enabled: root.motion
                    ColorAnimation { duration: 220; easing.type: Easing.OutCubic }
                  }
                }
              }
              trailingControl: Component {
                PanelActionButton {
                  iconText: Model.GLYPH_OPEN
                  tooltipText: "Open Paperclip — hold Shift for a new window"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: service.openBoard(shiftWatch.shiftHeld)

                  // The button's own clicked() carries no modifiers, so read them
                  // from the press and let it fall through to the button below.
                  MouseArea {
                    id: shiftWatch
                    property bool shiftHeld: false
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onPressed: function(mouse) {
                      shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                      mouse.accepted = false
                    }
                  }
                }
              }
            }

            // A hairline under the hero that sweeps while the probe is
            // running. Quieter than a spinner. It has a row of its own, always
            // reserved, so it can never overlap the title or the subtitle and
            // the panel does not shift when it fades in.
            Item {
              id: sweepTrack
              width: parent.width
              height: Style.space(2)
              opacity: service.refreshing && root.motion ? 1 : 0
              clip: true

              Behavior on opacity {
                enabled: root.motion
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
              }

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
              }

              Rectangle {
                id: sweep
                width: Math.max(Style.space(24), sweepTrack.width * 0.3)
                height: parent.height
                radius: height / 2
                color: root.foreground
                opacity: 0.5

                NumberAnimation on x {
                  running: sweepTrack.opacity > 0.01
                  from: -sweep.width
                  to: sweepTrack.width
                  duration: 1100
                  loops: Animation.Infinite
                  easing.type: Easing.InOutQuad
                }
              }
            }
          }

          // ------------------------------------------------- the service
          //
          // Whether Paperclip itself is running, and the one button for it.
          // The row is a fixed height, and the confirmation for stopping an
          // instance with agents at work replaces its detail line in place,
          // so asking never moves what is below.
          Item {
            id: serviceRow
            readonly property var control: service.serviceControl
            readonly property bool busy: control.state === "starting" || control.state === "stopping"
            // The big card above the list already offers Start, and Enter
            // reaches it; a second Start button would only repeat it.
            readonly property bool cardOffersStart: control.action === "start" &&
              root.action !== null && root.action.id === "start"
            visible: control.state !== "unavailable"
            width: parent.width
            height: Style.space(26)
            opacity: root.revealAt(1)
            transform: Translate { y: root.revealLift(1) }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(2)
              spacing: Style.space(8)

              Rectangle {
                id: serviceDot
                width: Style.space(6)
                height: Style.space(6)
                radius: width / 2
                Layout.alignment: Qt.AlignVCenter
                property real pulse: 0.9
                color: serviceRow.control.state === "stopped" ? root.urgent : root.foreground
                opacity: serviceRow.busy ? pulse : (serviceRow.control.state === "running" ? 0.9 : 0.65)

                SequentialAnimation on pulse {
                  running: root.motion && root.opened && serviceRow.busy
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutQuad }
                  NumberAnimation { to: 0.9; duration: 700; easing.type: Easing.InOutQuad }
                }
              }

              Text {
                textFormat: Text.PlainText
                text: serviceRow.control.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                Layout.alignment: Qt.AlignVCenter
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: service.stopArmed ? Model.stopConfirmText(serviceRow.control.working)
                                        : serviceRow.control.detail
                color: service.stopArmed ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              HeaderPill {
                visible: serviceRow.control.action !== "" && !serviceRow.cardOffersStart
                urgentPill: service.stopArmed
                label: service.stopArmed ? "press again" : serviceRow.control.action
                tooltip: service.stopArmed
                  ? Model.stopConfirmText(serviceRow.control.working)
                  : (serviceRow.control.action === "stop"
                      ? "Stop the Paperclip service — press v"
                      : "Start Paperclip — press v")
                Layout.alignment: Qt.AlignVCenter
                onClicked: service.toggleService()
              }
            }
          }

          // ----------------------------------------------------- the quiet
          //
          // Present only while something is keeping Paperclip quiet, and it
          // says who (you, Omarchy, or a focus session) and how to undo it.
          // Awake, it takes no room at all.
          BorderSurface {
            id: quietStrip
            visible: service.quiet.mode !== "awake"
            width: parent.width
            implicitHeight: quietRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
            opacity: root.revealAt(1)
            transform: Translate { y: root.revealLift(1) }

            RowLayout {
              id: quietRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_SLEEP
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: service.quiet.headline
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: service.quiet.detail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              HeaderPill {
                visible: service.quiet.mode === "plugin"
                label: "wake"
                tooltip: "End the snooze — press z"
                Layout.alignment: Qt.AlignVCenter
                onClicked: service.toggleSnooze(false)
              }

              HeaderPill {
                visible: service.quiet.mode === "omarchy"
                label: "focus"
                tooltip: "Let Paperclip through Omarchy's snooze — press p"
                Layout.alignment: Qt.AlignVCenter
                onClicked: service.toggleFocus()
              }

              HeaderPill {
                visible: service.quiet.mode === "focus"
                label: "end focus"
                tooltip: "Go back to Omarchy's snooze — press p"
                Layout.alignment: Qt.AlignVCenter
                onClicked: service.toggleFocus()
              }
            }
          }

          // ---------------------------------------------------- the numbers
          //
          // Three counts, always the same three and always in the same
          // places, so one glance at the top of the panel answers: is
          // anything waiting for me, is anything moving, did anything break.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            opacity: root.revealAt(1)
            transform: Translate { y: root.revealLift(1) }

            Repeater {
              model: root.tiles

              StatTile {
                required property var modelData
                Layout.fillWidth: true
                tile: modelData
                selected: root.activeFilter === modelData.key
                onClicked: root.cardFilter = Model.toggleTileFilter(root.activeFilter, modelData.key)
              }
            }
          }

          BorderSurface {
            visible: service.lastError !== ""
            width: parent.width
            implicitHeight: errorText.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.urgent, root.urgent)
            borderSpec: Border.controlSpec("normal", root.urgent, root.urgent)
            opacity: root.revealAt(2)
            transform: Translate { y: root.revealLift(2) }

            Text {
              id: errorText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              text: service.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          ActionCard {
            visible: root.action !== null
            width: parent.width
            opacity: root.revealAt(2)
            transform: Translate { y: root.revealLift(2) }
          }

          // What the probe found wrong, under the one button that fixes it.
          Column {
            visible: root.problems.length > 0
            width: parent.width
            spacing: Style.space(3)
            opacity: root.revealAt(3)
            transform: Translate { y: root.revealLift(3) }

            Repeater {
              model: root.problems

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Rectangle {
                  width: Style.space(4)
                  height: Style.space(4)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.urgent
                  opacity: 0.8
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width - Style.space(12)
                  text: String(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // ------------------------------------------------------ needs you
          Column {
            visible: root.needs.length > 0
            width: parent.width
            spacing: Style.space(8)
            opacity: root.revealAt(3)
            transform: Translate { y: root.revealLift(3) }

            // The section header carries the two controls that belong to this
            // list and nowhere else: which rows it shows, and the one batch
            // action over them.
            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: root.activeFilter === Model.TILE_FAILED
                  ? "FAILED RUNS · " + Model.retryableCount(service.report)
                  : "NEEDS YOU · " + service.inboxTotal
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                elide: Text.ElideRight
              }

              HeaderPill {
                label: Model.inboxFilterLabel(service.inboxFilter)
                tooltip: service.inboxFilter === Model.INBOX_ALL
                  ? "Showing everything, including what you snoozed or cleared — press f for needs me only"
                  : "Showing the open inbox — press f to also see what you snoozed or cleared"
                Layout.alignment: Qt.AlignVCenter
                onClicked: service.cycleInboxFilter()
              }

              HeaderPill {
                visible: service.retryableCount > 0
                iconText: Model.GLYPH_REFRESH
                urgentPill: root.retryArmed
                label: root.retryArmed
                  ? "press again"
                  : String(service.retryableCount > 999 ? "999+" : service.retryableCount)
                tooltip: root.retryArmed
                  ? "Try again on " + Math.min(service.retryableCount, service.retryAllLimit) +
                    " failed runs" + (root.inboxOwner !== "" ? " in " + root.inboxOwner : "") +
                    " — press again to start"
                  : "Try again on every failed run in this list, " + service.retryAllLimit +
                    " per press. Recovery hand-backs stay a row at a time."
                enabled: !service.writing
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.askRetryAll()
              }
            }

            Column {
              id: needsColumn
              width: parent.width
              spacing: Style.space(4)
              add: Transition {
                enabled: root.motion
                NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { properties: "scale"; from: 0.97; to: 1.0; duration: 220; easing.type: Easing.OutCubic }
              }
              populate: Transition {
                enabled: root.motion
                NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
              }
              move: Transition {
                enabled: root.motion
                NumberAnimation { properties: "y"; duration: 180; easing.type: Easing.OutCubic }
              }

              Repeater {
                model: root.needs
                PaperclipRow {
                  required property var modelData
                  required property int index
                  width: needsColumn.width
                  row: modelData
                  rowOffset: index
                  urgentRow: true
                }
              }
            }

            // Where the list stops, and the key that goes past it.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.moreWaiting > 0
              text: "+ " + root.moreWaiting + " more waiting" +
                    (root.showAllRows ? "  (open Paperclip for the rest)" : "  (press a)")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // What the batch is doing, or what it did. One line, no spinner.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: {
                if (service.batchProgress !== "") return service.batchProgress
                if (root.retryArmed) {
                  var count = Math.min(service.retryableCount, service.retryAllLimit)
                  return "Try again on " + count + " failed run" + (count === 1 ? "" : "s") +
                         (root.inboxOwner !== "" ? " in " + root.inboxOwner : "") +
                         "? Press T again."
                }
                return ""
              }
              color: root.retryArmed ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ----------------------------------------------------- working now
          Column {
            visible: root.moving.length > 0
            width: parent.width
            spacing: Style.space(8)
            opacity: root.revealAt(4)
            transform: Translate { y: root.revealLift(4) }

            PanelSectionHeader {
              text: "WORKING NOW · " + root.moving.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: movingColumn
              width: parent.width
              spacing: Style.space(4)
              add: Transition {
                enabled: root.motion
                NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { properties: "scale"; from: 0.97; to: 1.0; duration: 220; easing.type: Easing.OutCubic }
              }
              populate: Transition {
                enabled: root.motion
                NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
              }
              move: Transition {
                enabled: root.motion
                NumberAnimation { properties: "y"; duration: 180; easing.type: Easing.OutCubic }
              }

              Repeater {
                model: root.moving
                PaperclipRow {
                  required property var modelData
                  required property int index
                  width: movingColumn.width
                  row: modelData
                  rowOffset: root.needs.length + index
                  urgentRow: false
                }
              }
            }
          }

          // Nothing waiting and nothing running is a good state, so it gets
          // the mark and a sentence rather than an empty hole in the panel.
          Column {
            visible: root.rowCount === 0 && !service.trouble && root.action === null && root.activeFilter === ""
            width: parent.width
            spacing: Style.space(8)
            topPadding: Style.space(6)
            bottomPadding: Style.space(6)
            opacity: root.revealAt(3)
            transform: Translate { y: root.revealLift(3) }

            PaperclipMark {
              implicitWidth: Style.space(34)
              implicitHeight: Style.space(34)
              anchors.horizontalCenter: parent.horizontalCenter
              thickness: 18
              color: root.foreground
              opacity: 0.22
              motion: root.motion
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Nothing needs you and nothing is running."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }

      Column {
        id: footerBlock
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(12)

        PanelSeparator {
          foreground: root.foreground
          opacity: root.revealAt(5)
        }

        // ---------------------------------------------------------- footer
        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          opacity: root.revealAt(6)
          transform: Translate { y: root.revealLift(6) }

          // The keys this panel answers to, set as caps so they read as
          // keys rather than as a sentence.
          Flow {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(6)

            Repeater {
              model: Model.hintKeys(service.report, service.quiet)

              KeyHint {
                required property var modelData
                hint: modelData
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "· " + Model.notificationLabel(service.notifyLevel)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            iconText: Model.GLYPH_SLEEP
            tooltipText: service.quiet.mode === "plugin"
              ? "Wake Paperclip — hold Shift to snooze until morning instead"
              : "Snooze Paperclip for an hour — hold Shift to snooze until morning"
            foreground: root.foreground
            fontFamily: root.fontFamily
            Layout.alignment: Qt.AlignVCenter
            onClicked: service.toggleSnooze(snoozeShift.shiftHeld)

            MouseArea {
              id: snoozeShift
              property bool shiftHeld: false
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              onPressed: function(mouse) {
                shiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
                mouse.accepted = false
              }
            }
          }

          PanelActionButton {
            iconText: Model.GLYPH_REFRESH
            tooltipText: "Refresh"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !service.refreshing
            Layout.alignment: Qt.AlignVCenter
            onClicked: service.refresh()
          }

          PanelActionButton {
            iconText: Model.GLYPH_WRENCH
            tooltipText: "Fix Paperclip with your agent"
            foreground: root.foreground
            fontFamily: root.fontFamily
            Layout.alignment: Qt.AlignVCenter
            onClicked: service.runDoctor()
          }
        }
      }
    }
  }

  // The one thing to do about a Paperclip that is not simply working.
  component ActionCard: CursorSurface {
    id: card
    // With no rows to walk, the card is where the keyboard cursor lands, so
    // it takes the same highlight the rows would — one highlight on screen,
    // whether it was the mouse or the arrow keys that put it there.
    hasCursor: cardMouse.containsMouse || (root.cursorActive && root.rowCount === 0)
    bordered: true
    foreground: root.foreground
    implicitHeight: cardRow.implicitHeight + Style.spacing.rowPaddingX
    scale: hasCursor ? 1.006 : 1.0

    Behavior on scale {
      enabled: root.motion
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (root.action) service.run(root.action.id)
    }

    RowLayout {
      id: cardRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: service.trouble ? Model.GLYPH_WARN : Model.GLYPH_WRENCH
        color: service.trouble ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.action ? root.action.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.action ? root.action.detail : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        text: Model.GLYPH_CHEVRON
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
        opacity: card.hasCursor ? 0.9 : 0.25
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: card.hasCursor ? 0 : Style.space(3)

        Behavior on opacity {
          enabled: root.motion
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
        Behavior on Layout.rightMargin {
          enabled: root.motion
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  // One attention item or one live run.
  component PaperclipRow: CursorSurface {
    id: rowItem
    property var row: null
    property int rowOffset: 0
    property bool urgentRow: false
    readonly property bool isCritical: urgentRow && row &&
      (String(row.severity) === "critical" || String(row.severity) === "high")
    readonly property bool clickable: row && String(row.url || "") !== ""
    readonly property int groupCount: row ? Number(row.count || 1) : 1
    readonly property bool retryable: row === null ? false : row.retryable === true
    // The server's own words about why this row refused, if it did.
    readonly property string note: row ? service.rowNote(row.key) : ""
    readonly property bool hiddenRow: row === null ? false : row.hidden === true

    hasCursor: root.cursorActive && root.rowIndex === rowOffset
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // A rule that grows out of the left edge under the cursor. It gives the
    // row a direction to be read in without adding a second fill color.
    Rectangle {
      width: Style.space(2)
      height: rowItem.hasCursor ? rowItem.height * 0.62 : 0
      radius: width / 2
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      color: rowItem.urgentRow ? root.urgent : root.foreground
      opacity: rowItem.hasCursor ? 0.9 : 0

      Behavior on height {
        enabled: root.motion
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
      Behavior on opacity {
        enabled: root.motion
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: rowItem.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setRowCursor(rowItem.rowOffset)
      // A row's url opens in a window of its own, so the click always shows
      // the item. Shift forces a window for the board url too.
      onClicked: function(mouse) {
        if (rowItem.row && rowItem.row.url)
          service.openUrl(rowItem.row.url, (mouse.modifiers & Qt.ShiftModifier) !== 0)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        id: rowDot
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        color: rowItem.urgentRow
                 ? (rowItem.isCritical ? root.urgent : Qt.darker(root.urgent, 1.4))
                 : root.foreground
        opacity: rowItem.urgentRow ? 1.0 : 0.65
        Layout.alignment: Qt.AlignVCenter

        // A live run breathes; something waiting for a person holds still and
        // keeps its full color. Slow enough that a list of them stays calm.
        SequentialAnimation {
          running: root.motion && root.opened && !rowItem.urgentRow
          loops: Animation.Infinite
          NumberAnimation { target: rowDot; property: "opacity"; to: 0.3; duration: 1500; easing.type: Easing.InOutQuad }
          NumberAnimation { target: rowDot; property: "opacity"; to: 0.75; duration: 1500; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          // A group says how many rows it is. The count is the number of
          // listed rows it stands for, and pressing a verb acts on all of them.
          text: Model.rowLabel(rowItem.row) +
                (rowItem.groupCount > 1 ? "  ×" + rowItem.groupCount : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: {
            if (!rowItem.row) return ""
            var parts = []
            if (rowItem.hiddenRow) {
              parts.push(rowItem.row.snoozedUntil ? "snoozed" : "cleared")
            }
            if (rowItem.row.detail) parts.push(String(rowItem.row.detail))
            if (rowItem.row.ago) parts.push(String(rowItem.row.ago))
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // A refusal shows the server's own sentence, on the row it is about.
        // A button that fails quietly is worse than no button.
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: rowItem.note !== ""
          text: rowItem.note
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // Only a row with a failed attempt gets a Try again. The rest are
      // waiting on a person, and there a retry would either do nothing or
      // approve something nobody read.
      PanelActionButton {
        visible: rowItem.retryable
        iconText: Model.GLYPH_REFRESH
        fontSize: Style.font.iconSmall
        size: Style.space(20)
        tooltipText: Model.retryLabel(rowItem.row) +
                     (rowItem.groupCount > 1 ? " · " + rowItem.row.retryableCount + " rows" : "")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !service.writing
        opacity: rowItem.hasCursor ? 1.0 : 0.45
        Layout.alignment: Qt.AlignVCenter
        onClicked: service.retryRow(rowItem.row)

        Behavior on opacity {
          enabled: root.motion
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }

      // Only rows that open something advertise that they do.
      Text {
        textFormat: Text.PlainText
        visible: rowItem.clickable
        text: Model.GLYPH_CHEVRON
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
        opacity: rowItem.hasCursor ? 0.85 : 0
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: rowItem.hasCursor ? 0 : Style.space(4)

        Behavior on opacity {
          enabled: root.motion
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on Layout.rightMargin {
          enabled: root.motion
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  // A small labelled control for a section header: the filter position, and
  // the batch action with its count. Reads as a pill rather than as a button,
  // because neither belongs to a single row.
  component HeaderPill: BorderSurface {
    id: pill
    property string iconText: ""
    property string label: ""
    property string tooltip: ""
    property bool urgentPill: false
    readonly property color accentColor: urgentPill ? root.urgent : root.foreground

    signal clicked()

    implicitWidth: pillRow.implicitWidth + Style.space(12)
    implicitHeight: Style.space(18)
    radius: Style.cornerRadius
    color: pillMouse.containsMouse || pill.urgentPill
      ? Style.hoverFillFor(pill.accentColor, pill.accentColor)
      : Style.normalFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec(pillMouse.containsMouse ? "hover-cursor" : "normal",
                                  pill.accentColor, Color.accent)
    opacity: pill.enabled ? 1.0 : 0.45

    Behavior on color {
      enabled: root.motion
      ColorAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        visible: pill.iconText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: pill.iconText
        color: pill.accentColor
        font.family: root.fontFamily
        font.pixelSize: Math.max(9, Style.font.caption)
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: pill.label
        color: pill.accentColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: pill.urgentPill
        renderType: Text.NativeRendering
      }
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: pill.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: pill.enabled
      onClicked: pill.clicked()
    }

    PanelToolTip {
      visible: pill.tooltip !== "" && pillMouse.containsMouse
      text: pill.tooltip
      fontFamily: root.fontFamily
    }
  }

  // One of the three counts under the hero, and a filter over the lists
  // below it. A tile with something in it borrows that state's color and can
  // be pressed; an empty one stays quiet chrome and does nothing.
  component StatTile: BorderSurface {
    id: statTile
    property var tile: null
    property bool selected: false
    readonly property int value: tile ? Number(tile.value || 0) : 0
    readonly property color tone: root.toneColor(tile ? String(tile.tone) : "quiet")
    readonly property bool pressable: value > 0
    readonly property bool hovered: tileMouse.containsMouse

    signal clicked()

    implicitHeight: tileColumn.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: statTile.selected
      ? Style.selectedFillFor(statTile.tone, statTile.tone)
      : (statTile.value > 0
        ? Style.hoverFillFor(statTile.tone, statTile.tone)
        : Style.normalFillFor(root.foreground, Color.accent))
    borderSpec: Border.controlSpec(
      statTile.selected ? "selected" : (statTile.hovered ? "hover-cursor" : "normal"),
      statTile.value > 0 ? statTile.tone : root.foreground, Color.accent)

    Behavior on color {
      enabled: root.motion
      ColorAnimation { duration: 260; easing.type: Easing.OutCubic }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: statTile.radius
      anchors.rightMargin: statTile.radius
      height: Style.space(2)
      radius: height / 2
      color: statTile.tone
      opacity: statTile.selected ? 1 : 0

      Behavior on opacity {
        enabled: root.motion
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: statTile.pressable
      enabled: statTile.pressable
      cursorShape: statTile.pressable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: statTile.clicked()
    }

    Column {
      id: tileColumn
      anchors.centerIn: parent
      width: parent.width - Style.space(12)
      spacing: Style.space(1)

      CountText {
        width: parent.width
        value: statTile.value
        color: statTile.tone
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: statTile.tile ? String(statTile.tile.label) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
  }

  // A number that counts to its new value and flicks once when it lands, so
  // a change that happened while you were not looking is still noticeable.
  component CountText: Text {
    id: counter
    property int value: 0
    property real shown: 0

    textFormat: Text.PlainText
    text: String(Math.round(shown))
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.heading
    font.bold: true
    horizontalAlignment: Text.AlignHCenter
    renderType: Text.NativeRendering

    Component.onCompleted: shown = value
    onValueChanged: {
      shown = value
      if (root.motion) valuePop.restart()
    }

    Behavior on shown {
      enabled: root.motion
      NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
    }

    SequentialAnimation {
      id: valuePop
      NumberAnimation { target: counter; property: "scale"; to: 1.12; duration: 120; easing.type: Easing.OutCubic }
      NumberAnimation { target: counter; property: "scale"; to: 1.0; duration: 240; easing.type: Easing.OutBack }
    }
  }

  // One keyboard hint in the footer: the key in a cap, the verb beside it.
  component KeyHint: Row {
    id: hintRow
    property var hint: null
    spacing: Style.space(4)

    BorderSurface {
      implicitWidth: Math.max(Style.space(14), keyCap.implicitWidth + Style.space(8))
      implicitHeight: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

      Text {
        id: keyCap
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: hintRow.hint ? String(hintRow.hint.key) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.max(8, Style.font.caption - 1)
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: hintRow.hint ? String(hintRow.hint.label) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
