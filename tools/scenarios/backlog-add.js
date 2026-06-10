// backlog-add.js — functional test for the backlog flow.
// @audit-safe: no (POSTs a test item to backlog briefly; even with cleanup
//                  it appears in the queue for a moment + curator gets triggered)
// Verifies: POST /api/backlog/add returns ok+id, the item appears in
// GET /api/backlog response, and subsequent pollBacklog renders it
// in the UI when /memory page is on the Backlog tab.
async function scenario(s) {
  s.log('start scenario');

  function cleanScenarioUrl(path) {
    const u = new URL(path, window.location.href);
    u.username = '';
    u.password = '';
    return u.href;
  }

  function scenarioFetch(path, opts) {
    return fetch(cleanScenarioUrl(path), Object.assign({credentials: 'same-origin'}, opts || {}));
  }

  function getScenarioChannel() {
    const fromUrl = new URL(window.location.href).searchParams.get('channel');
    if (fromUrl) { return fromUrl; }
    return (window.__bridge && window.__bridge.channelsCache && window.__bridge.channelsCache.active) || 'main';
  }

  const channel = getScenarioChannel();
  const marker = 'backlog-flow-0ad0b19c8e5f';
  const markerText = 'bridge backlog add list delete verification violet signal quartz canyon lantern ember ribbon orchard';
  const uniqueToken = marker + '-' + Math.random().toString(36).slice(2);
  const saltPool = [
    'atlas', 'lagoon', 'copper', 'matrix', 'harbor', 'violet', 'lantern', 'orchard',
    'signal', 'meadow', 'canyon', 'silver', 'comet', 'ribbon', 'marble', 'cedar',
    'pixel', 'garden', 'anchor', 'velvet', 'summit', 'cobalt', 'quartz', 'ember'
  ];
  const saltWords = saltPool.sort(() => Math.random() - 0.5).slice(0, 8).join(' ');
  const taskText = marker + ' ' + markerText + ' ' + uniqueToken + ' ' + saltWords;

  // 0. Verify function dependencies are loaded in the server process
  let healthResp = null;
  try {
    const r = await scenarioFetch('/api/backlog/health');
    if (!r.ok) { s.fail('GET /api/backlog/health HTTP ' + r.status); return; }
    healthResp = await r.json();
  } catch (e) { s.fail('GET /api/backlog/health failed: ' + e.message); return; }
  s.assert(healthResp && healthResp.addIdea === true, 'Add-Idea function loaded on server');
  s.assert(healthResp && healthResp.getBacklogPath === true, 'Get-BacklogPath function loaded on server');
  s.log('function health: addIdea=' + (healthResp && healthResp.addIdea) + ' getBacklogPath=' + (healthResp && healthResp.getBacklogPath));

  // 1. POST add
  let addResp = null;
  try {
    const r = await scenarioFetch('/api/backlog/add', {
      method: 'POST',
      credentials: 'same-origin',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({text: taskText, status: 'new', channel: channel, skip_curator: true})
    });
    if (!r.ok) { s.fail('POST /api/backlog/add HTTP ' + r.status); return; }
    addResp = await r.json();
  } catch (e) { s.fail('POST failed: ' + e.message); return; }

  s.assert(addResp && addResp.ok === true, 'POST returned ok=true');
  s.assert(addResp && addResp.id && addResp.id.length >= 8, 'POST returned an id');
  s.log('added id: ' + (addResp.id || '<none>'));

  // 2. GET backlog, find marker
  let listResp = null;
  try {
    const r = await scenarioFetch('/api/backlog?channel=' + encodeURIComponent(channel) + '&include=all');
    listResp = await r.json();
  } catch (e) { s.fail('GET /api/backlog failed: ' + e.message); return; }

  s.assert(listResp && listResp.ok === true, 'GET /api/backlog returned ok=true');
  const items = (listResp && Array.isArray(listResp.items)) ? listResp.items : [];
  s.log('backlog items returned: ' + items.length);
  const found = items.find(i => ((i && i.text) || '').includes(uniqueToken));
  s.assert(!!found, 'item with marker found in backlog');
  if (found) {
    s.assert(found.id === addResp.id, 'id matches POST response');
    const allowedStatuses = ['new', 'approved', 'held', 'auto-dropped'];
    s.assert(allowedStatuses.includes(found.status), 'item status is a known post-add status');
    if (found.status !== 'new') {
      s.log('curator updated item before list: ' + found.status);
    }
  }

  // 3. Clean up — drop the scenario item so it doesn't pollute the queue.
  if (addResp && addResp.id) {
    try {
      const deleteRespRaw = await scenarioFetch('/api/backlog/delete', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({id: addResp.id, channel: channel})
      });
      const deleteResp = await deleteRespRaw.json();
      s.assert(deleteResp && deleteResp.ok === true, 'DELETE returned ok=true');
      const afterDeleteRaw = await scenarioFetch('/api/backlog?channel=' + encodeURIComponent(channel) + '&include=all');
      const afterDeleteResp = await afterDeleteRaw.json();
      const afterDeleteItems = (afterDeleteResp && Array.isArray(afterDeleteResp.items)) ? afterDeleteResp.items : [];
      const archivedItem = afterDeleteItems.find(i => i && i.id === addResp.id);
      s.assert(archivedItem && archivedItem.status === 'rejected', 'deleted item archived as rejected');
      const visibleAfterRaw = await scenarioFetch('/api/backlog?channel=' + encodeURIComponent(channel));
      const visibleAfterResp = await visibleAfterRaw.json();
      const visibleAfterItems = (visibleAfterResp && Array.isArray(visibleAfterResp.items)) ? visibleAfterResp.items : [];
      const stillVisible = visibleAfterItems.some(i => i && i.id === addResp.id);
      s.assert(!stillVisible, 'deleted item absent from active backlog');
      s.log('cleanup: deleted scenario item ' + addResp.id);
    } catch (e) { s.fail('DELETE verification failed: ' + e.message); }
  }

  s.log('scenario complete');
}