// Bar button + popout. Presentation only: every value comes from Service.qml.
// Structure and property names follow jkoestinger.vpn, which is the working
// reference for Omarchy's bar-widget contract on this machine.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ky.jellyfin-nowplaying"
  ipcTarget: "ky.jellyfin-nowplaying"
  manageIpc: false

  // ⛔ WITHOUT THESE THE WIDGET IS INVISIBLE. A Panel with no implicit size gets
  // allocated zero width by the bar: it loads, runs, logs nothing fatal, and simply
  // never appears. Learned from taildrop, the minimal working reference on this box.
  // Idle -> zero width, which is how "quiet when nobody is watching" is honestly
  // expressed; a FAULT keeps its width so broken never looks like idle.
  // Zero width hides the pill. Two ways to have nothing worth showing: a healthy
  // server with nothing playing, and a poll that has failed but is not yet a
  // fault — the boot case. A widget still holding streams keeps showing them,
  // marked stale, rather than vanishing mid-session while one poll is in doubt.
  implicitWidth: (jf.ok && jf.count === 0)
                 || (!jf.ok && !jf.faulted && jf.count === 0)
                 ? 0 : button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family


  // Live playback position: the polled value plus seconds elapsed since that poll.
  // Reads `jf.tick` so the binding re-evaluates every second; frozen while paused,
  // and never allowed past the runtime (a stream that ends between polls would
  // otherwise keep counting up).
  function livePos(s) {
    if (!s) return 0
    var p = s.position_sec + (s.paused ? 0 : jf.tick)
    return (s.duration_sec > 0 && p > s.duration_sec) ? s.duration_sec : p
  }

  // A runtime is read as hours+minutes, not as 103 minutes: 6159 -> "1h 43m".
  // Rounded to the nearest minute, which is why 1h 42m 39s reads 1h 43m.
  function fmtTotal(s) {
    var m = Math.round(s / 60)
    var h = Math.floor(m / 60)
    return h > 0 ? h + "h " + (m % 60) + "m" : m + "m"
  }

  // A countdown keeps seconds while they still matter, and drops to hours+minutes
  // once there is more than an hour left (nobody reads "82:15" as time remaining).
  function fmtLeft(s) {
    if (s >= 3600) {
      var m = Math.round(s / 60)
      return Math.floor(m / 60) + "h " + (m % 60) + "m"
    }
    var mm = Math.floor(s / 60), x = s % 60
    return mm + ":" + (x < 10 ? "0" : "") + x
  }

  JellyfinService {
    id: jf
    refreshIntervalSec: (root.settings && root.settings.refreshIntervalSec) ? root.settings.refreshIntervalSec : 10
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The official Jellyfin mark, from dashboard-icons. Replaces a hand-drawn
    // jellyfish-with-play-triangle: the real logo is a rounded triangle, not a
    // jellyfish, so it is also harder to confuse with the Seerr orb sitting beside
    // it. "Playing" is already carried by the widget being visible at all — it
    // hides when idle — so the icon does not need to say it twice.
    // BarIconButton renders `iconComponent` through a Loader when it is non-null and
    // hides the glyph Text, so `text` must stay empty or both would count as content.
    text: ""
    iconComponent: Component {
      Image {
        source: Qt.resolvedUrl("jellyfin.png")
        // Render at 2x the slot and downscale: the mark is 512px, and letting Image
        // scale a large source directly leaves it soft on a HiDPI bar.
        sourceSize.width: 64
        sourceSize.height: 64
        fillMode: Image.PreserveAspectFit
        smooth: true
        opacity: (jf.ok && jf.count === 0) ? 0.55 : 1.0
      }
    }
    // Quiet when the server is reachable and nobody is watching; a FAULT stays lit,
    // because a hidden widget and a broken widget must not look the same.
    dimmed: jf.ok && jf.count === 0
    tooltipText: "Jellyfin: " + jf.barSummary + (jf.anyTranscoding ? " (transcoding)" : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) jf.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) { if (t === "r" || t === "R") jf.refresh() }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.space(10)

          // The bar gives each widget ONE fixed square slot, so the popup header is
          // where the mark gets to sit beside its name. SVG here because it is
          // rendered larger than the bar icon and scales without a second asset.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Image {
              source: Qt.resolvedUrl("jellyfin.svg")
              Layout.preferredWidth: Style.space(20)
              Layout.preferredHeight: Style.space(20)
              sourceSize.width: 40
              sourceSize.height: 40
              fillMode: Image.PreserveAspectFit
              smooth: true
            }
            Text {
              text: "Jellyfin"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { Layout.fillWidth: true }
          }

          // Fault state, worded
          Text {
            Layout.fillWidth: true
            visible: jf.faulted
            text: "Not available — " + jf.error + (jf.stale ? " (showing last known)" : "")
            color: root.urgent
            font.family: root.fontFamily
            wrapMode: Text.WordWrap
          }

          // Both config faults get a next step. "bad config" means the file is
          // there but unusable, which is a different fix from "write one".
          Text {
            Layout.fillWidth: true
            visible: jf.faulted
                     && (jf.error === "not configured" || jf.error === "bad config")
            text: jf.error === "not configured"
                  ? "Create ~/.config/omarchy-jellyfin/config.json with url and token."
                  : "~/.config/omarchy-jellyfin/config.json needs a url and a token. "
                    + "The field names must be exactly that — replace only the values."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: jf.ok && jf.count === 0
            text: "Nobody is watching."
            color: root.dim
            font.family: root.fontFamily
          }

          Repeater {
            model: jf.streams
            delegate: RowLayout {
              id: streamRow
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(10)

              // Series poster for episodes, the item's own for films — chosen by the
              // backend, which is where Jellyfin knowledge lives. Absent for content
              // with no artwork (some music, some live), and the thumbnail collapses
              // to zero width rather than showing a broken-image box.
              //
              // Jellyfin serves these unauthenticated, so no credential rides in the
              // URL. asynchronous:true keeps a slow server from stalling the panel's
              // first paint; the layout is already sized, so nothing reflows when it
              // lands.
              // Structure copied verbatim from ky.seerr-requests, which is the working
              // reference for a remote Image in this shell. Do NOT gate `visible` on
              // `status === Image.Ready`: an Image that starts invisible at zero layout
              // width never gets driven to load, so the status it is waiting for never
              // arrives and the poster silently never appears.
              Image {
                Layout.alignment: Qt.AlignTop
                visible: !!modelData.poster_url
                source: modelData.poster_url || ""
                sourceSize.width: Style.space(120)  // 2x the slot: stays crisp on HiDPI
                Layout.preferredWidth: Style.space(60)
                Layout.preferredHeight: Style.space(90)   // posters are 2:3
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true                  // never let a slow server stall the panel
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(3)

              // Click the title to open the item in Jellyfin. The URL is built by the
              // backend, so QML never needs to know the server address or the route.
              Text {
                id: titleText
                Layout.fillWidth: true
                text: modelData.title
                color: titleMouse.containsMouse && modelData.web_url ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.bold: true
                font.underline: titleMouse.containsMouse && !!modelData.web_url
                wrapMode: Text.WordWrap

                MouseArea {
                  id: titleMouse
                  anchors.fill: parent
                  hoverEnabled: !!modelData.web_url
                  enabled: !!modelData.web_url
                  cursorShape: modelData.web_url ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: {
                    Qt.openUrlExternally(modelData.web_url)
                    root.close()          // opening a browser over the panel leaves it stranded
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                text: modelData.user + " · " + modelData.device + " · " + modelData.client
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              // His own curated label, verbatim from Jellyfin's stream DisplayTitle:
              // "DV P7 FEL CM v4.0 - 4K - HEVC [88.0 Mb/s]". Carries HDR/DV/FEL-or-MEL/CM
              // in one line — and it is the ONLY source for FEL vs MEL, since Jellyfin
              // reports DOVIWithEL for both.
              Text {
                Layout.fillWidth: true
                visible: !!modelData.video_label
                text: modelData.video_label || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // What the server is doing right now: direct play vs transcode
              Text {
                Layout.fillWidth: true
                text: {
                  var br = modelData.bitrate_mbps ? modelData.bitrate_mbps + " Mb/s" : "bitrate n/a"
                  if (!modelData.transcoding)
                    return "DIRECT PLAY · " + br + (modelData.video_codec ? " · " + modelData.video_codec : "")
                  var why = (modelData.reasons && modelData.reasons.length) ? modelData.reasons.join(", ") : "reason unknown"
                  var hw = modelData.hw_accel ? " · hw: " + modelData.hw_accel : " · software"
                  return "TRANSCODE · " + br + " · " + why + hw
                }
                color: modelData.transcoding ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              // progress
              Rectangle {
                Layout.fillWidth: true
                height: Style.space(4)
                radius: height / 2
                color: Qt.darker(root.foreground, 3.0)
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  color: modelData.paused ? root.dim : root.foreground
                  width: modelData.duration_sec > 0
                         ? parent.width * Math.min(1, root.livePos(modelData) / modelData.duration_sec)
                         : 0
                  // Match the 1 Hz tick so the bar creeps instead of stepping.
                  Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
                }
              }
              Text {
                // What he asked for: total runtime + how much is LEFT, counting down
                // live. Elapsed is already conveyed by the bar above, so it is not
                // repeated here.
                text: {
                  var d = modelData.duration_sec
                  if (!d || d <= 0) return "runtime unknown"
                  var left = Math.max(0, d - root.livePos(modelData))
                  return root.fmtLeft(left) + " left · " + root.fmtTotal(d) + " total" +
                         (modelData.paused ? "  (paused)" : "")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Transport, per SESSION — Jellyfin routes commands to the client that
              // is playing, so two devices watching the same film are two independent
              // remotes. Disabled with a stated reason when the client cannot be
              // controlled, rather than hidden: a missing row reads as a bug.
              RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Style.space(2)
                spacing: Style.space(2)

                readonly property bool live: modelData.controllable && jf.busyKey === ""
                readonly property string why: modelData.control_error || "Nothing playing"

                PanelActionButton {
                  iconText: "󰒮"
                  tooltipText: modelData.controllable ? "Previous" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "previous")
                }
                PanelActionButton {
                  // Plain text, not a glyph: the nf-md rewind-30 codepoint is not
                  // verified present in this bar's font, and a missing glyph renders
                  // as tofu with no way to tell from here.
                  iconText: "−30"
                  tooltipText: modelData.can_seek ? "Back 30s" : "This client cannot seek"
                  foreground: (modelData.controllable && modelData.can_seek) ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live && modelData.can_seek
                  onClicked: jf.control(modelData.session_id, "back30")
                }
                PanelActionButton {
                  iconText: modelData.paused ? "󰐊" : "󰏤"
                  tooltipText: modelData.controllable ? (modelData.paused ? "Play" : "Pause") : parent.why
                  foreground: modelData.controllable ? root.foreground : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "playpause")
                }
                PanelActionButton {
                  iconText: "+30"
                  tooltipText: modelData.can_seek ? "Forward 30s" : "This client cannot seek"
                  foreground: (modelData.controllable && modelData.can_seek) ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live && modelData.can_seek
                  onClicked: jf.control(modelData.session_id, "fwd30")
                }
                PanelActionButton {
                  iconText: "󰒭"
                  tooltipText: modelData.controllable ? "Next" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "next")
                }
                PanelActionButton {
                  iconText: "󰓛"
                  tooltipText: modelData.controllable ? "Stop" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "stop")
                }

                Item { Layout.fillWidth: true }

                PanelActionButton {
                  iconText: "󰝟"
                  tooltipText: modelData.controllable ? "Toggle mute" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "mute")
                }
                PanelActionButton {
                  iconText: "󰝞"
                  tooltipText: modelData.controllable ? "Volume down" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "voldown")
                }
                PanelActionButton {
                  iconText: "󰝝"
                  tooltipText: modelData.controllable ? "Volume up" : parent.why
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: parent.live
                  onClicked: jf.control(modelData.session_id, "volup")
                }
              }

              // Why the buttons are dead, stated rather than left to be guessed.
              Text {
                Layout.fillWidth: true
                visible: !modelData.controllable
                text: modelData.control_error
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              }
            }
          }

          // A failed command, named. Sits below the streams so one message covers
          // whichever session it came from.
          Text {
            Layout.fillWidth: true
            visible: jf.actionError !== ""
            text: "Command failed — " + jf.actionError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
