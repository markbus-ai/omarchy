import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GitPulseModel.js" as GitPulse

BarWidget {
  id: root
  moduleName: "omarchy.git-pulse"

  readonly property var toplevel: ToplevelManager.activeToplevel

  readonly property real ttlMs: Math.max(1000, Number(setting("ttl", 10000)))
  readonly property bool showUntracked: setting("showUntracked", false) === true
  readonly property bool showAheadBehind: setting("showAheadBehind", false) === true
  readonly property real maxLabelWidth: Number(setting("maxWidth", 160))

  property var state: null
  // Focus-churn guard: one entry per toplevel object, so switching between
  // windows never re-runs the git pipeline for one measured within ttlMs.
  property var cache: []
  property var pendingToplevel: null
  property bool rerunPending: false
  property bool popupOpen: false
  property string shortStatusText: ""
  property string githubUrl: ""
  readonly property var chips: root.state ? GitPulse.countEntries(root.state) : []

  readonly property bool showState: state !== null && state.isRepo === true
  readonly property string label: state ? GitPulse.labelText(state, root.showUntracked, root.showAheadBehind) : ""
  readonly property string tooltip: state ? GitPulse.tooltipText(state) : ""

  visible: showState && !vertical
  implicitWidth: visible ? Math.min(root.maxLabelWidth, labelText.implicitWidth) + Style.space(14) : 0
  implicitHeight: visible ? Style.bar.statusSlot : 0

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  onToplevelChanged: debounceTimer.restart()

  // Debounced focus follower. The pipeline is deliberately sequential and
  // never allowed to stack: while one measurement is in flight a new focus
  // only marks rerunPending, and the completion handler drains it.
  function refresh() {
    var current = root.toplevel
    if (!current) {
      root.state = null
      return
    }

    var entry = GitPulse.cacheLookup(root.cache, current, Date.now(), root.ttlMs)
    if (entry) {
      root.state = GitPulse.parseStatus(entry.statusText)
      return
    }

    if (cwdProc.running || gitProc.running) {
      root.rerunPending = true
      return
    }

    root.pendingToplevel = current
    cwdProc.running = true
  }

  function drainRerun() {
    if (!root.rerunPending) return
    root.rerunPending = false
    root.refresh()
  }

  function onCwdReady(cwd) {
    var target = root.pendingToplevel
    if (!target) {
      root.drainRerun()
      return
    }

    // $HOME is the terminal-cwd script's failure fallback, so a cwd that
    // equals it means the focused window is not a resolvable terminal (or
    // really does sit in $HOME, which is not a repo worth pill space either).
    // Either way the pill must stay hidden while it stays cached.
    var home = Quickshell.env("HOME") || ""
    if (cwd === "" || (home !== "" && cwd === home)) {
      GitPulse.cacheUpsert(root.cache, target, "", Date.now())
      root.state = GitPulse.parseStatus("")
      root.drainRerun()
      return
    }

    gitProc.command = ["omarchy-git-status", cwd]
    gitProc.running = true
  }

  function onStatusReady(text) {
    var target = root.pendingToplevel
    if (target) {
      GitPulse.cacheUpsert(root.cache, target, text, Date.now())
      root.state = GitPulse.parseStatus(text)
    }
    root.drainRerun()
  }

  function openPopup() {
    root.popupOpen = true
    root.shortStatusText = ""
    root.githubUrl = ""
    if (root.state && !statusShortProc.running) {
      statusShortProc.command = ["git", "-C", root.state.topLevel, "status", "--short"]
      statusShortProc.running = true
    }
    if (root.state && !remoteProc.running) {
      remoteProc.command = ["git", "-C", root.state.topLevel, "remote", "get-url", "origin"]
      remoteProc.running = true
    }
  }

  function close() {
    root.popupOpen = false
  }

  // Shell-safe single-quote wrapping for values passed to bar.run. The
  // classic '"'"' escaping keeps embedded single quotes from breaking out.
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  // Semantic color for a count chip; monochrome canvas with urgent red only
  // where it means something (the repo's Color roles: accent/urgent/muted).
  function chipColor(kind) {
    if (kind === "conflict") return Color.urgent
    if (kind === "untracked") return Color.muted
    if (kind === "staged") return Color.accent
    return Color.foreground
  }

  function actionCopy() {
    var value = GitPulse.copyValue(root.state)
    if (value === "") return
    root.bar.run("wl-copy " + root.shellQuote(value))
    root.bar.run("omarchy-notification-send " + root.shellQuote("Branch " + value + " copied to clipboard"))
  }

  function actionOpenTerminal() {
    if (!root.state) return
    root.bar.run("setsid uwsm-app -- xdg-terminal-exec --dir=" + root.shellQuote(root.state.topLevel))
  }

  function actionOpenGithub() {
    if (root.githubUrl === "") return
    root.bar.run("omarchy-launch-webapp " + root.shellQuote(root.githubUrl))
  }

  Timer {
    id: debounceTimer
    interval: 180
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: cwdProc
    command: ["omarchy-cmd-terminal-cwd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCwdReady(String(text).trim())
    }
  }

  Process {
    id: gitProc
    command: ["omarchy-git-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatusReady(text)
    }
  }

  Process {
    id: statusShortProc
    command: ["git", "status", "--short"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.shortStatusText = String(text).trim()
    }
  }

  Process {
    id: remoteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.githubUrl = GitPulse.githubUrlFromRemote(String(text).trim())
    }
  }

  Row {
    id: pill
    anchors.fill: parent
    spacing: Style.space(6)
    visible: root.showState && !root.vertical

    Text {
      id: labelText
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      renderType: Text.NativeRendering
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.showState ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton

    onClicked: function(mouse) {
      if (!root.showState) return
      if (mouse.button === Qt.LeftButton) root.openPopup()
    }
    onEntered: if (root.bar && root.showState) root.bar.showTooltip(root, root.tooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(popupColumn.implicitHeight)

    Column {
      id: popupColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: GitPulse.GIT_GLYPH
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
        }

        Text {
          width: parent.width - Style.space(6) - implicitWidth
          anchors.verticalCenter: parent.verticalCenter
          text: root.state ? GitPulse.branchLabel(root.state) : ""
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }
      }

      Text {
        width: parent.width
        text: root.state ? root.state.topLevel : ""
        color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: root.chips.length > 0

        Repeater {
          model: root.chips

          delegate: Rectangle {
            required property var modelData

            radius: Math.max(Style.space(3), 4)
            color: {
              var c = root.chipColor(modelData.kind)
              return Qt.rgba(c.r, c.g, c.b, 0.16)
            }
            height: chipText.implicitHeight + Style.space(6)
            width: chipText.implicitWidth + Style.space(14)

            Text {
              id: chipText
              anchors.centerIn: parent
              text: modelData.count + " " + modelData.kind
              color: root.chipColor(modelData.kind)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      PanelSeparator {
        visible: root.shortStatusText !== ""
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Flickable {
        id: statusList
        visible: root.shortStatusText !== ""
        width: parent.width
        height: Math.min(statusLines.implicitHeight, Style.space(220))
        clip: true
        contentWidth: width
        contentHeight: statusLines.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Text {
          id: statusLines
          width: statusList.width
          text: root.shortStatusText
          color: root.bar ? Qt.darker(root.bar.foreground, 1.2) : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          lineHeight: Style.space(18)
          wrapMode: Text.NoWrap
        }

        ScrollBar.vertical: ScrollBar { policy: statusLines.implicitHeight > statusList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Row {
        width: parent.width
        layoutDirection: Qt.RightToLeft
        spacing: Style.space(6)

        PanelActionButton {
          iconText: "\uf0c5"
          tooltipText: "Copy branch"
          onClicked: root.actionCopy()
        }

        PanelActionButton {
          iconText: "\ue795"
          tooltipText: "Open terminal in repository"
          onClicked: root.actionOpenTerminal()
        }

        PanelActionButton {
          iconText: "\ue709"
          tooltipText: "Open on GitHub"
          visible: root.githubUrl !== ""
          onClicked: root.actionOpenGithub()
        }
      }
    }
  }
}