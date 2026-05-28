// smoke.js — minimal scenario that immediately reports success.
// Used to verify the scenario boot pipeline works end-to-end.
// @audit-safe: yes (no DOM mutations, no API calls beyond the boot beacon)
async function scenario(s) {
  s.log('smoke scenario reached');
  s.assert(true, 'smoke test always passes');
  s.log('about to call done()');
}
