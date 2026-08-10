// Owns the poll and the parsed state. Knows nothing about how it is drawn.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: svc

  property int refreshIntervalSec: 10
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- state the panel reads ----
  property bool ok: false
  property string error: "starting"
  property var streams: []
  property bool stale: false          // last poll failed but we still have old data

  // Seconds since the last AUTHORITATIVE poll. The panel adds this to a stream's
  // position_sec so the readout advances every second instead of jumping by
  // refreshIntervalSec (10 s by default) — the poll stays the source of truth and
  // resets this to 0, so drift can never accumulate past one interval.
  property int tick: 0
  readonly property int count: streams ? streams.length : 0
  readonly property bool anyTranscoding: {
    for (var i = 0; i < count; i++) if (streams[i].transcoding) return true
    return false
  }
  readonly property string barSummary: {
    if (!ok) return error
    if (count === 0) return "nothing playing"
    return count === 1 ? streams[0].title : count + " streams"
  }

  Process {
    id: poll
    command: ["bash", svc.pluginDir + "/backend.sh"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        if (raw === "") { svc.stale = svc.count > 0; svc.ok = false; svc.error = "no output"; return }
        try {
          var d = JSON.parse(raw)
          svc.ok = !!d.ok
          svc.error = d.error ? String(d.error) : ""
          if (d.ok) { svc.streams = d.streams || []; svc.stale = false; svc.tick = 0 }
          else { svc.stale = svc.count > 0 }   // keep last-known, mark it stale
        } catch (e) {
          svc.ok = false; svc.error = "unparseable"; svc.stale = svc.count > 0
        }
      }
    }
  }

  function refresh() { if (!poll.running) poll.running = true }

  Timer {
    interval: Math.max(5, svc.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: svc.refresh()
  }

  // 1 Hz clock for the live position. Deliberately gated on `count > 0` so an idle
  // server costs zero per-second wakeups on a laptop — it only runs while something
  // is actually playing.
  Timer {
    interval: 1000
    running: svc.count > 0
    repeat: true
    onTriggered: svc.tick += 1
  }
}
