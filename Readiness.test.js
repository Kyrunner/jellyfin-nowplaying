const assert = require("node:assert/strict")
const R = require("./Readiness.js")

const cfg = { refreshIntervalSec: 60, retrySec: 5, faultAfterSec: 45 }

// Drives the machine the way Readiness.qml does: the next event happens
// nextDelayMs after the previous one, plus however long the poll itself took,
// plus any clock step the machine is being lied to about. Elapsed time is
// accumulated per poll now, so the tests have to walk the timeline rather than
// jump along it -- jumping is precisely what the machine refuses to believe.
function sim(config, startMs) {
  return {
    cfg: config,
    now: startMs === undefined ? 0 : startMs,
    state: R.initialState(),
    step: function (event, pollMs, clockStepMs) {
      this.now += this.state.nextDelayMs + (pollMs || 0) + (clockStepMs || 0)
      this.state = R.decide(this.state, event, this.now, this.cfg)
      return this.state
    },
    fail: function (pollMs, clockStepMs) { return this.step("failure", pollMs, clockStepMs) },
    succeed: function (pollMs) { return this.step("success", pollMs, 0) }
  }
}

// Cold start, continuously failing: quiet inside the grace window, faulted at
// 45s of real time, and retrying at 5s throughout that window.
let s = sim(cfg)
let first = s.fail()
assert.equal(first.faulted, false)
assert.equal(first.nextDelayMs, 5000)      // retry cadence while in grace
while (!s.state.faulted) {
  assert.ok(s.now < 45000, "faulted before the grace window was up")
  assert.equal(s.state.nextDelayMs, 5000)
  s.fail()
}
assert.equal(s.now, 45000)                 // 45s of real time, not 9 retries of anything
assert.equal(s.state.nextDelayMs, 60000)   // steady cadence once faulted

// A poll against a dead host blocks for its own 10s timeout, so failures arrive
// every ~15s rather than every 5s. That must still fault at ~45s of REAL time:
// summing scheduled delays instead would push it out past two minutes.
s = sim(cfg)
s.fail(10000)
assert.equal(s.state.faulted, false)
let blockedFrom = s.now
while (!s.state.faulted) s.fail(10000)
assert.equal(s.now - blockedFrom, 45000)

// A success inside the window means it never faults, and resets the clock.
s = sim(cfg)
s.fail()
s.succeed()
assert.equal(s.state.faulted, false)
assert.equal(s.state.failingMs, null)
assert.equal(s.state.nextDelayMs, 60000)

// After a success, a new failure run gets a fresh 45s -- not an instant fault.
let resumedAt = s.now
s.fail()
assert.equal(s.state.faulted, false)
assert.equal(s.state.failingMs, 0)         // fresh run: nothing accumulated yet
let runStart = s.now
assert.equal(runStart - resumedAt, 60000)  // it waited out the steady interval first
while (!s.state.faulted) s.fail()
assert.equal(s.now - runStart, 45000)      // then a full fresh 45s

// A success clears a fault.
s.succeed()
assert.equal(s.state.faulted, false)
assert.equal(s.state.failingMs, null)

// ---- the clock is not to be trusted -------------------------------------
// timesyncd corrects the clock a few seconds into boot, which is the middle of
// this very window; suspend/resume moves it by hours.

// A large FORWARD step mid-run must not manufacture a fault. Three failures in
// (10s of grace used), the clock jumps an hour: the jump is credited as one
// scheduled interval, so nothing faults and the remaining grace is still real.
s = sim(cfg)
s.fail(); s.fail(); s.fail()
assert.equal(s.state.faulted, false)
assert.equal(s.state.failingMs, 10000)
s.fail(0, 3600 * 1000)                     // +1h clock step
assert.equal(s.state.faulted, false, "a forward clock step faulted the widget early")
assert.equal(s.state.failingMs, 15000)     // one interval's worth, not an hour's
let afterStep = s.now
while (!s.state.faulted) s.fail()
assert.equal(s.now - afterStep, 30000)     // the other 30s of grace, in real seconds

// A single step is never enough on its own: from a standing start, one failure
// then an enormous jump still leaves the widget quiet.
s = sim(cfg)
s.fail()
s.fail(0, 86400 * 1000)                    // +1 day
assert.equal(s.state.faulted, false)

// A BACKWARD step must not park the widget in "undecided" forever. The clock
// jumps back ten minutes mid-run; the negative interval is credited as the
// scheduled delay, so progress continues and the fault still arrives.
s = sim(cfg)
s.fail(); s.fail()
s.fail(0, -600 * 1000)                     // -10m clock step
assert.equal(s.state.failingMs, 10000)     // still moved forward, not backwards
let polls = 0
while (!s.state.faulted) {
  polls += 1
  assert.ok(polls < 20, "a backward clock step delayed the fault indefinitely")
  s.fail()
}
assert.equal(s.state.failingMs, 45000)

// A nonsense clock (NaN) is treated the same way: credited as the scheduled
// delay, so the machine still converges on a decision.
s = R.decide(R.initialState(), "failure", 0, cfg)
s = R.decide(s, "failure", NaN, cfg)
assert.equal(s.faulted, false)
assert.equal(s.failingMs, 5000)

// Never retry SLOWER than the steady cadence. nzbget polls every 2s while
// active, which is below retrySec.
const fast = { refreshIntervalSec: 2, retrySec: 5, faultAfterSec: 45 }
const f = R.decide(R.initialState(), "failure", 0, fast)
assert.equal(f.nextDelayMs, 2000)
assert.equal(f.faulted, false)

// A fast cadence still measures real time: a 2s cadence with 10s-blocking polls
// faults on elapsed seconds, not on 22 scheduled intervals.
const fastSim = sim(fast)
fastSim.fail(10000)
const fastFrom = fastSim.now
while (!fastSim.state.faulted) fastSim.fail(10000)
const fastElapsed = fastSim.now - fastFrom
assert.ok(fastElapsed >= 45000 && fastElapsed <= 45000 + 12000,
          "fast cadence drifted off real time: " + fastElapsed)

console.log("Readiness: all assertions passed")
