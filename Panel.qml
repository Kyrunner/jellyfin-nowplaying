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
  implicitWidth: (jf.ok && jf.count === 0) ? 0 : button.implicitWidth
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
    // Our own mark (see make_icon.py): Jellyfin's visual language — bell, tentacles,
    // purple->blue gradient — with a play triangle so the icon says "playing".
    // BarIconButton renders `iconComponent` through a Loader when it is non-null and
    // hides the glyph Text, so `text` must stay empty or both would count as content.
    text: ""
    iconComponent: Component {
      Image {
        source: Qt.resolvedUrl("nowplaying.png")
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

          Text {
            Layout.fillWidth: true
            text: "Jellyfin"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          // Fault state, worded
          Text {
            Layout.fillWidth: true
            visible: !jf.ok
            text: "Not available — " + jf.error + (jf.stale ? " (showing last known)" : "")
            color: root.urgent
            font.family: root.fontFamily
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
            delegate: ColumnLayout {
              required property var modelData
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
            }
          }
        }
      }
    }
  }
}
