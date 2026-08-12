// Decides when to poll, and when a failure is worth showing.
//
// Pure on purpose: no timers, no I/O, time is passed in. Readiness.qml is a
// thin shell around this so the logic can be tested with node, the way
// taildrop's Model.js is.
//
// The rule is uniform -- there is NO startup special case. A fault is shown
// only after faultAfterSec of CONTINUOUS failure, whenever that happens. At
// boot that keeps the widget quiet while the network comes up; mid-session it
// means a brief blip keeps showing last-known data instead of flashing an
// error banner across the bar.
//
// Elapsed failure time is ACCUMULATED per poll rather than measured as one
// span, because the clock underneath us is not trustworthy in exactly the
// window this measures: systemd-timesyncd makes its first correction seconds
// into boot, and suspend/resume moves the clock by hours. Each interval is
// sanity-checked before it is added, so one clock step contributes one
// scheduled interval instead of an arbitrary jump -- forward steps cannot
// manufacture a fault, backward steps cannot hide one.

// A poll against an unreachable host blocks until the backend's own HTTP
// timeout (10s) before it reports failure, so the real gap between two
// failures is the scheduled delay plus that, plus process spawn overhead.
// Anything past this is a clock step or a suspend, not a slow poll.
var MAX_POLL_OVERRUN_MS = 15000

function initialState() {
  return { failingMs: null, faulted: false, nextDelayMs: 0, lastEventMs: null, scheduledMs: 0 }
}

// How much real time to credit between the previous event and this one. The
// measured delta is used when it is plausible; otherwise the delay we actually
// scheduled stands in for it, which is what the interval would have been had
// the clock held still.
function creditMs(prior, nowMs) {
  var scheduled = prior.scheduledMs > 0 ? prior.scheduledMs : 0
  var delta = nowMs - prior.lastEventMs
  if (!isFinite(delta) || delta < 0 || delta > scheduled + MAX_POLL_OVERRUN_MS) return scheduled
  return delta
}

function decide(state, event, nowMs, config) {
  var steadyMs = Math.max(1, config.refreshIntervalSec) * 1000
  var retryMs = Math.max(1, config.retrySec) * 1000
  var faultAfterMs = Math.max(0, config.faultAfterSec) * 1000

  if (event === "success") {
    return {
      failingMs: null, faulted: false, nextDelayMs: steadyMs,
      lastEventMs: nowMs, scheduledMs: steadyMs
    }
  }

  var prior = state || initialState()
  var inRun = prior.failingMs !== null && prior.failingMs !== undefined
             && prior.lastEventMs !== null && prior.lastEventMs !== undefined
  // The first failure of a run has no interval behind it yet, so it starts the
  // accumulator at zero -- one failed poll is never, by itself, a fault.
  var failingMs = inRun ? prior.failingMs + creditMs(prior, nowMs) : 0
  var faulted = failingMs >= faultAfterMs

  // Never retry slower than the steady cadence: nzbget and navidrome can be
  // configured down to 2-3s, which is below retrySec.
  var nextDelayMs = faulted ? steadyMs : Math.min(retryMs, steadyMs)

  return {
    failingMs: failingMs,
    faulted: faulted,
    nextDelayMs: nextDelayMs,
    lastEventMs: nowMs,
    scheduledMs: nextDelayMs
  }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { initialState: initialState, decide: decide }
}
