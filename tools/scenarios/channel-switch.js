// channel-switch.js — functional test for the channel-switch UI flow.
// @audit-safe: yes (toggles channels but doesn't write to chat/backlog; user sees nothing)
// Reproduces user's complaint: "при переключении вкладок мигает, не могу переключиться".
// Tests:
//   1. Switch from initial channel to another channel — channelsCache.active updates.
//   2. Rapid double-click: second switch must NOT be silently ignored (must supersede).
//   3. Round-trip back — uses cache, no leftover .channel-switching class.
//   4. Active log shows messages (we rendered something).
async function scenario(s) {
  s.log('start scenario');

  const B = window.__bridge;
  if (!B) { s.fail('window.__bridge not exposed'); return; }

  await s.waitFor(() => B.channelsCache && Array.isArray(B.channelsCache.items) && B.channelsCache.items.length >= 2, 8000, 'channelsCache has >=2 channels');
  if (!B.channelsCache || !Array.isArray(B.channelsCache.items)) { s.fail('no channelsCache'); return; }

  const initial = String(B.channelsCache.active || '');
  s.log('initial channel: ' + initial);

  const target = B.channelsCache.items.map(x => String(x.slug)).find(slug => slug && slug !== initial);
  if (!target) { s.fail('no other channel to switch to'); return; }
  s.log('target channel: ' + target);

  // --- Step 1: switch to target.
  const t1 = Date.now();
  await B.switchChannel(target);
  await s.waitFor(() => String(B.channelsCache.active) === target, 5000, 'channelsCache.active updated to ' + target);
  const switchMs = Date.now() - t1;
  s.log('switch initial -> target took ' + switchMs + 'ms');

  await s.waitFor(() => B.channelSwitchInProgress === false, 5000, 'channelSwitchInProgress cleared');
  s.assert(B.channelSwitchInProgress === false, 'channelSwitchInProgress is false after switch');

  // --- Step 2: rapid double-click — the LATER click must win.
  s.log('rapid double-switch test');
  B.switchChannel(initial);          // intent A: back
  await s.wait(30);                   // 30ms "oops"
  B.switchChannel(target);           // intent B: actually stay on target (later click wins)
  await s.waitFor(() => String(B.channelsCache.active) === target && B.channelSwitchInProgress === false, 15000, 'rapid double-switch resolves to target');
  s.assert(String(B.channelsCache.active) === target, 'after double-switch, active = ' + target);

  // --- Step 3: switch back to initial. Cache hit should be fast.
  const t3 = Date.now();
  await B.switchChannel(initial);
  await s.waitFor(() => String(B.channelsCache.active) === initial && B.channelSwitchInProgress === false, 10000, 'back to initial');
  const backMs = Date.now() - t3;
  s.log('switch back (cached): ' + backMs + 'ms');

  // --- Step 4: no leftover .channel-switching class.
  const logEl = document.getElementById('log');
  if (logEl) {
    s.assert(!logEl.classList.contains('channel-switching'), '#log has no leftover .channel-switching class');
  } else { s.fail('no #log element'); }

  // --- Step 5: cache sanity.
  if (B.channelMessageCache) {
    const cached = Object.keys(B.channelMessageCache);
    s.log('channelMessageCache has ' + cached.length + ' channels: ' + cached.join(','));
    s.assert(cached.includes(initial), 'cache has initial channel');
    s.assert(cached.includes(target), 'cache has target channel');
  }

  // --- Step 6: visual sanity.
  const msgsCount = document.querySelectorAll('#log .msg').length;
  s.log('#log .msg count after roundtrip: ' + msgsCount);
  s.assert(msgsCount > 0, 'log has messages after switch (rendered something)');

  s.log('scenario complete');
}
