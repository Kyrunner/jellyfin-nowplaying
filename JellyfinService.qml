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
  property string endpoint: ""        // "lan" or "public": which address answered

  // True only once a failure has persisted past the grace window, or when the
  // problem is a configuration one, which is never transient. Panels render
  // errors from this, not from !ok, so a cold boot stays quiet.
  readonly property bool faulted: readiness.faulted
                                  || svc.error === "not configured"
                                  || svc.error === "bad config"

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
        if (raw === "") { svc.stale = svc.count > 0; svc.ok = false; svc.error = "no output"; readiness.failed(); return }
        try {
          var d = JSON.parse(raw)
          svc.ok = !!d.ok
          svc.error = d.error ? String(d.error) : ""
          if (d.ok) {
            svc.streams = d.streams || []; svc.stale = false; svc.tick = 0
            svc.endpoint = d.endpoint ? String(d.endpoint) : ""
            readiness.succeeded()
          } else {
            svc.stale = svc.count > 0   // keep last-known, mark it stale
            readiness.failed()
          }
        } catch (e) {
          svc.ok = false; svc.error = "unparseable"; svc.stale = svc.count > 0
          readiness.failed()
        }
      }
    }
  }

  // Set while a command is in flight so every button disables at once, rather than
  // letting a second click race the first.
  property string busyKey: ""
  property string actionError: ""

  Process {
    id: action
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busyKey = ""
        settle.restart()
      }
    }
  }

  // Deferred, not immediate: the client ACKs through Jellyfin before it has applied
  // the command, so polling straight away reads the PRE-command state and the panel
  // flips a beat later. Same lag the Kodi widget accounts for.
  Timer {
    id: settle
    interval: 400
    repeat: false
    onTriggered: svc.refresh()
  }

  function refresh() { if (!poll.running) poll.running = true }

  function control(sessionId, act) {
    if (action.running || busyKey !== "" || !sessionId) return
    busyKey = sessionId + "/" + act
    actionError = ""
    action.command = ["bash", pluginDir + "/backend.sh", "control", String(sessionId), String(act)]
    action.running = true
  }

  // Owns the poll cadence. While a poll is failing it retries faster than the
  // configured interval and stays silent, so the ~10s between the bar appearing
  // and WiFi associating does not render as a fault. See Readiness.qml.
  Readiness {
    id: readiness
    refreshIntervalSec: Math.max(5, svc.refreshIntervalSec)
    onPoll: svc.refresh()
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
