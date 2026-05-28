// message-send.js — functional test for the basic chat-message flow.
// Verifies: typing into composer, hitting Send, message appears in #log
// with seq, and the server recorded it (next poll returns it via cache).
async function scenario(s) {
  s.log('start scenario');
  const B = window.__bridge;
  if (!B) { s.fail('window.__bridge not exposed'); return; }

  // Wait for chat to be ready (channelsCache populated + log container present).
  await s.waitFor(() => B.channelsCache && document.getElementById('log'), 5000, 'chat UI ready');
  const initialMsgCount = document.querySelectorAll('#log .msg').length;
  s.log('initial msg count: ' + initialMsgCount);

  // Find composer input (textarea or contenteditable).
  const composer = document.querySelector('#composer textarea, textarea#composer, [data-composer="input"], textarea');
  if (!composer) { s.fail('no composer textarea found'); return; }

  // Generate a unique message body so we can find it back unambiguously.
  const marker = 'scenario-msg-' + Date.now().toString(36);
  composer.focus();
  composer.value = marker;
  composer.dispatchEvent(new Event('input', {bubbles: true}));
  s.log('typed: ' + marker);

  // Find Send button.
  const sendBtn = document.querySelector('button#sendBtn, button[type="submit"]#send, button.send, [data-send]')
    || Array.from(document.querySelectorAll('button')).find(b => /отправ|send/i.test(b.textContent || ''));
  if (!sendBtn) { s.fail('no Send button found'); return; }
  sendBtn.click();
  s.log('clicked Send');

  // Wait for poll to pick up the new message — up to 4s (poll runs every 1.5s).
  const found = await s.waitFor(() => {
    return Array.from(document.querySelectorAll('#log .msg')).some(el => (el.textContent || '').includes(marker));
  }, 6000, 'message appears in #log');

  s.assert(found, 'message rendered in log');
  const newCount = document.querySelectorAll('#log .msg').length;
  s.log('new msg count: ' + newCount);
  s.assert(newCount > initialMsgCount, 'log grew by at least 1');

  // Verify cache also got it (for sanity — same data path).
  if (B.channelMessageCache) {
    const slot = B.channelMessageCache[B.channelsCache.active];
    if (slot && slot.msgs) {
      const inCache = slot.msgs.some(m => ((m && m.text) || '').includes(marker));
      s.assert(inCache, 'message in channelMessageCache');
    }
  }

  s.log('scenario complete');
}
