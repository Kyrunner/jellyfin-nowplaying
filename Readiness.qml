// Owns when to poll and whether a failure is worth showing. Thin shell around
// Readiness.js, which holds the decision so it can be tested under node.
//
// The machine state is called `machine`, NOT `state`: Item.state is a built-in
// string property for QML state groups, and binding an object to it breaks at
// runtime.
import QtQuick
import "Readiness.js" as Logic

Item {
  id: root

  property int refreshIntervalSec: 60
  property int retrySec: 5
  property int faultAfterSec: 45

  property var machine: Logic.initialState()
  readonly property bool faulted: root.machine.faulted

  signal poll()

  function succeeded() { root.advance("success") }
  function failed()    { root.advance("failure") }

  function advance(event) {
    root.machine = Logic.decide(root.machine, event, Date.now(), {
      refreshIntervalSec: root.refreshIntervalSec,
      retrySec: root.retrySec,
      faultAfterSec: root.faultAfterSec
    })
    timer.interval = root.machine.nextDelayMs
    timer.restart()
  }

  // triggeredOnStart is deliberately false. restart() on a triggeredOnStart
  // timer fires onTriggered immediately, which would make poll -> outcome ->
  // restart -> poll a tight infinite loop. The first poll is issued explicitly
  // below instead, preserving the old triggeredOnStart behaviour.
  Timer {
    id: timer
    interval: Math.max(1, root.retrySec) * 1000
    running: false
    repeat: true
    onTriggered: root.poll()
  }

  // The interval binding above is left alone: reassigning it here would destroy
  // it, and retrySec is endpoint-dependent in at least one plugin, so the
  // pre-first-decision cadence has to keep tracking it. advance() takes the
  // interval over from the first outcome onwards.
  Component.onCompleted: {
    timer.start()
    root.poll()
  }
}
