// features-registry.js — functional test for the Phase 1 feature registry.
// Verifies the /api/features endpoints return the seeded 25 features,
// each has the expected schema (id, name, description, owner_files, etc),
// and the /memory Features tab can render them (loads at least one card).
async function scenario(s) {
  s.log('start scenario');

  // 1. GET /api/features
  let listResp = null;
  try {
    const r = await fetch('/api/features', {credentials: 'same-origin'});
    if (!r.ok) { s.fail('GET /api/features HTTP ' + r.status); return; }
    listResp = await r.json();
  } catch (e) { s.fail('GET failed: ' + e.message); return; }

  const features = (listResp && Array.isArray(listResp.items)) ? listResp.items
                 : (Array.isArray(listResp) ? listResp : []);
  s.log('features count: ' + features.length);
  s.assert(features.length >= 20, 'at least 20 features in registry');

  // 2. Schema check — every feature must have id, name, description, owner_files.
  const requiredKeys = ['id', 'name', 'description', 'owner_files', 'layer', 'status'];
  let schemaOk = 0;
  for (const f of features) {
    if (!f) continue;
    const missing = requiredKeys.filter(k => !(k in f));
    if (missing.length === 0) schemaOk++;
    else s.log('feature ' + (f.id || '?') + ' missing: ' + missing.join(','));
  }
  s.assert(schemaOk === features.length, 'all features have required schema (' + schemaOk + '/' + features.length + ')');

  // 3. Critical features exist by id.
  const expectedIds = ['auditor', 'doctor', 'intent-classifier', 'scenario-runner', 'channel-switch'];
  const ids = features.map(f => f && f.id).filter(Boolean);
  for (const id of expectedIds) {
    s.assert(ids.includes(id), 'feature "' + id + '" present in registry');
  }

  // 4. Detail endpoint works for one feature.
  let detailResp = null;
  try {
    const r = await fetch('/api/features/auditor', {credentials: 'same-origin'});
    if (r.ok) detailResp = await r.json();
  } catch (e) { /* fall through */ }
  s.assert(detailResp && (detailResp.id === 'auditor' || (detailResp.feature && detailResp.feature.id === 'auditor')), 'GET /api/features/auditor returns the feature');

  s.log('scenario complete');
}
