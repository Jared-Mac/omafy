// Exercise the service's JavaScript with deterministic process/network adapters.
// The offscreen smoke test separately verifies it loads in the QML runtime.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const repo = path.resolve(__dirname, '..');
const serviceSource = fs.readFileSync(path.join(repo, 'Service.qml'), 'utf8');
const functions = serviceSource.match(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm).join('\n');
const Spotify = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(repo, 'Spotify.js'), 'utf8').replace('.pragma library', ''), Spotify);

function timer() {
  return { running: false, restarts: 0, restart() { this.running = true; this.restarts++; }, stop() { this.running = false; } };
}

function file() {
  return { contents: '', text() { return this.contents; }, setText(value) { this.contents = value; } };
}

function service(overrides = {}) {
  const requests = [];
  class XHR {
    static DONE = 4;
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(name, value) { (this.headers ||= {})[name] = value; }
    send(body) { this.body = body; requests.push(this); }
    getResponseHeader() { return '10'; }
    reply(status, payload) {
      this.status = status;
      this.responseText = payload ? JSON.stringify(payload) : '';
      this.readyState = XHR.DONE;
      this.onreadystatechange();
    }
  }
  const ctx = {
    Spotify, Date, XMLHttpRequest: XHR, requests,
    authHelper: '/test/omafy-auth', clientId: 'test-client',
    sessionGeneration: 0, authEnabled: true, authChecked: false, loggedIn: true,
    tokenBusy: false, forceTokenRefresh: false, tokenWaiters: [],
    tokenProcess: { running: false }, loginProcess: { running: false }, logoutProcess: { running: false },
    loginBusy: false, loggingOut: false, loginAfterLogout: false, loggingIn: false,
    loginRestart: false, loginCancelled: false,
    accessToken: 'old-token', tokenExpiresAt: Date.now() + 3600000, cacheKey: 'account-a',
    hasTrack: false, isPlaying: false, trackUri: '', deviceId: '', localDeviceName: 'Omafy',
    devices: [], localPlayerStarter: { running: false }, playHereAttempts: 0, shuffle: false,
    likedCache: {}, browseCache: {}, backoffUntil: {}, playlists: [], playlistsLoading: false,
    lastError: '', lastPollAt: 0, notice: '', openList: null, queueRows: [],
    libraryTtlMs: 600000, likedTtlMs: 21600000, likedCacheMax: 2000,
    searchTtlMs: 600000, recentTtlMs: 120000,
    libraryFile: file(), cacheFile: file(),
    ...Object.fromEntries(['saveLibrarySoon', 'saveCacheSoon', 'noticeTimer', 'settlePoll',
      'trackEndPoll', 'playAfterTransfer', 'volumeDebounce'].map(name => [name, timer()])),
    ...overrides,
  };
  ctx.root = ctx;
  vm.createContext(ctx);
  vm.runInContext(functions, ctx);
  ctx.completeToken = (token = 'new-token', cacheKey = 'account-a', exitCode = 0) => {
    ctx.tokenProcess.running = false;
    ctx.finishToken(JSON.stringify({ access_token: token, expires_at: Date.now() / 1000 + 3600,
      cache_key: cacheKey }), exitCode, ctx.tokenProcess.generation, ctx.tokenProcess.forced);
  };
  return ctx;
}

test('401 forces a fresh token, then retries with the replacement bearer', () => {
  const s = service();
  let status;
  s.api('GET', '/me/player', null, value => status = value);
  s.requests[0].reply(401);
  assert.deepEqual(Array.from(s.tokenProcess.command), ['/test/omafy-auth', 'token', '--force-refresh']);
  assert.equal(s.requests.length, 1);
  s.completeToken();
  assert.equal(s.requests[1].headers.Authorization, 'Bearer new-token');
  s.requests[1].reply(204);
  assert.equal(status, 204);
});

test('concurrent 401s share a refresh and late 401s reuse the replacement', () => {
  const s = service();
  for (let i = 0; i < 3; i++) s.api('GET', '/me/player', null, () => {});
  s.requests[0].reply(401);
  s.requests[1].reply(401);
  s.completeToken();
  assert.equal(s.tokenBusy, false);
  s.requests[2].reply(401);
  assert.equal(s.tokenBusy, false);
  assert.equal(s.requests.length, 6);
  for (const request of s.requests.slice(3)) assert.equal(request.headers.Authorization, 'Bearer new-token');
});

test('401 during an ordinary token lookup waits for a forced refresh', () => {
  const s = service();
  s.api('GET', '/first', null, () => {});
  s.tokenExpiresAt = 0;
  s.api('GET', '/second', null, () => {});
  assert.equal(s.tokenProcess.forced, false);
  s.requests[0].reply(401);
  s.completeToken('old-token');
  assert.equal(s.requests.length, 1);
  assert.equal(s.tokenBusy, true);
  assert.equal(s.tokenProcess.forced, true);
  s.completeToken();
  assert.equal(s.requests.length, 3);
});

test('a second 401 is returned without an infinite refresh loop', () => {
  const s = service();
  let result;
  s.api('GET', '/me/player', null, status => result = status);
  s.requests[0].reply(401);
  s.completeToken();
  s.requests[1].reply(401);
  assert.equal(result, 401);
  assert.equal(s.tokenBusy, false);
});

test('logout waits for the token writer and discards its late result', () => {
  const s = service({ accessToken: '' });
  let called = false;
  s.withToken(() => called = true);
  s.logout();
  assert.equal(s.logoutProcess.running, false);
  assert.equal(s.authEnabled, false);
  s.completeToken();
  assert.equal(called, false);
  assert.equal(s.loggedIn, false);
  assert.equal(s.accessToken, '');
  assert.equal(s.logoutProcess.running, true);
});

test('logout waits for a cancelled login before deleting credentials', () => {
  const s = service();
  s.login();
  s.logout();
  assert.equal(s.loginCancelled, true);
  assert.equal(s.loginProcess.running, false);
  assert.equal(s.logoutProcess.running, false);
  s.loginBusy = false;
  s.completeLogout();
  assert.equal(s.logoutProcess.running, true);
  s.login();
  assert.equal(s.loginAfterLogout, true);
  assert.equal(s.loginProcess.running, false);
});

test('late API responses cannot repopulate state after logout', () => {
  const s = service();
  s.loadQueue();
  s.logout();
  s.requests[0].reply(200, { queue: [{ type: 'track', uri: 'spotify:track:private' }] });
  assert.equal(s.queueRows.length, 0);
  assert.equal(s.queueLoading, false);
  assert.equal(s.loggedIn, false);
});

test('logout clears private UI data and replaces persisted caches', () => {
  const s = service({
    browseCache: { playlists: { t: Date.now(), v: [{ id: 'private' }] } },
    likedCache: { private: { t: Date.now(), v: true } },
    playlists: [{ id: 'private' }], openList: { id: 'private' }, queueRows: [{ id: 'private' }],
  });
  s.logout();
  for (const name of ['browseCache', 'likedCache']) assert.equal(Object.keys(s[name]).length, 0);
  assert.equal(s.playlists.length, 0);
  assert.equal(s.openList, null);
  assert.equal(s.queueRows.length, 0);
  assert.equal(s.cacheKey, '');
  assert.equal(s.libraryFile.text().includes('private'), false);
  assert.equal(s.cacheFile.text().includes('private'), false);
});

test('restore accepts only caches for the authenticated grant', () => {
  const s = service({ cacheKey: '' });
  const library = key => JSON.stringify({ version: 2, cacheKey: key, entries: { playlists: { t: Date.now(), v: [{ id: 'private' }] } } });
  const state = key => JSON.stringify({ version: 2, cacheKey: key, liked: { private: { t: Date.now(), v: true } } });
  s.restoreLibrary(library('account-a'));
  s.restoreCache(state('account-a'));
  assert.equal(Object.keys(s.browseCache).length, 0);
  s.cacheKey = 'account-b';
  s.restoreLibrary(library('account-a'));
  s.restoreCache(state('account-a'));
  assert.equal(Object.keys(s.likedCache).length, 0);
  s.restoreLibrary(library('account-b'));
  s.restoreCache(state('account-b'));
  assert.equal(s.browseCache.playlists.v[0].id, 'private');
  assert.equal(s.likedCache.private.v, true);
});

test('startup restores the matching cache without starting a second token lookup', () => {
  const s = service({ cacheKey: '', accessToken: '' });
  s.cacheFile.setText(JSON.stringify({ version: 2, cacheKey: 'account-a', lastTrack: { uri: 'spotify:track:test' } }));
  s.withToken(() => {});
  s.completeToken();
  assert.equal(s.trackUri, 'spotify:track:test');
  assert.equal(s.requests.length, 1);
  assert.equal(s.requests[0].headers.Authorization, 'Bearer new-token');
  assert.equal(s.tokenBusy, false);
});

test('CLI account changes invalidate old callbacks and in-memory data', () => {
  const s = service({ playlists: [{ id: 'old-account' }] });
  s.loadQueue();
  s.tokenExpiresAt = 0;
  s.withToken(() => assert.fail('old waiter must be invalidated'));
  s.completeToken('new-account-token', 'account-b');
  s.requests[0].reply(200, { queue: [{ type: 'track', uri: 'spotify:track:private' }] });
  assert.equal(s.cacheKey, 'account-b');
  assert.equal(s.playlists.length, 0);
  assert.equal(s.queueRows.length, 0);
});

test('lists include all pages beyond the former caps', () => {
  const s = service();
  s.openLiked();
  for (let page = 0; page < 7; page++) {
    const offset = page * 50;
    s.requests[page].reply(200, {
      items: Array.from({ length: 50 }, (_, i) => ({ track: { type: 'track', uri: `spotify:track:${offset + i}` } })),
      next: page === 6 ? null : `https://api.spotify.com/v1/me/tracks?offset=${offset + 50}`,
    });
  }
  assert.equal(s.openList.rows.length, 350);
  assert.equal(s.browseCache.liked.v.length, 350);
  assert.equal(s.openListLoading, false);
});

test('failed later pages are not cached as a complete list', () => {
  const s = service();
  s.openLiked();
  s.requests[0].reply(200, { items: [], next: 'https://api.spotify.com/v1/me/tracks?offset=50' });
  s.requests[1].reply(429);
  assert.equal(s.browseCache.liked, undefined);
  assert.match(s.openListError, /quota/);
});

test('network failures never display queue success', () => {
  const s = service();
  s.queueRow({ uri: 'spotify:track:test', title: 'Test' });
  s.requests[0].reply(0);
  assert.equal(s.notice, '');
  assert.match(s.lastError, /connection/);
});

test('missing credentials also fail a queue action', () => {
  const s = service({ authEnabled: false });
  s.queueRow({ uri: 'spotify:track:test', title: 'Test' });
  assert.equal(s.notice, '');
  assert.match(s.lastError, /sign-in/);
  assert.equal(s.requests.length, 0);
});

test('successful queue actions clear stale errors', () => {
  const s = service({ lastError: 'previous failure' });
  s.queueRow({ uri: 'spotify:track:test', title: 'Test' });
  s.requests[0].reply(204);
  assert.equal(s.lastError, '');
  assert.equal(s.notice, 'Added to queue: Test');
});

test('transport failures remain visible for generic player commands', () => {
  const s = service();
  s.command('POST', '/me/player/next');
  s.requests[0].reply(0);
  assert.match(s.lastError, /connection/);
});

test('shuffle on an idle receiver waits for playback and targets that receiver', () => {
  const s = service({ openList: { kind: 'playlist', uri: 'spotify:playlist:test' } });
  s.playOpenList(true);
  assert.equal(s.requests.length, 1);
  assert.match(s.requests[0].url, /\/devices$/);
  s.requests[0].reply(200, { devices: [{ id: 'local-id', name: 'Omafy' }] });
  assert.equal(s.requests.length, 2);
  assert.match(s.requests[1].url, /\/play\?device_id=local-id$/);
  assert.equal(s.shuffle, false);
  s.requests[1].reply(204);
  assert.match(s.requests[2].url, /\/shuffle\?state=true&device_id=local-id$/);
  s.requests[2].reply(204);
  assert.equal(s.shuffle, true);
});

test('a vanished active device falls back locally before setting shuffle', () => {
  const s = service({ deviceId: 'gone' });
  s.startPlayback({ context_uri: 'spotify:playlist:test' }, false);
  s.requests[0].reply(404);
  s.requests[1].reply(200, { devices: [{ id: 'local-id', name: 'Omafy' }] });
  s.requests[2].reply(204);
  assert.match(s.requests[3].url, /state=false&device_id=local-id$/);
});

test('failed playback does not send shuffle; failed shuffle reports its error', () => {
  const s = service({ deviceId: 'active' });
  s.startPlayback({ uris: ['spotify:track:test'] }, true);
  s.requests[0].reply(0);
  assert.equal(s.requests.length, 1);
  assert.match(s.lastError, /connection/);
  s.startPlayback({ uris: ['spotify:track:test'] }, true);
  s.requests[1].reply(204);
  s.requests[2].reply(403);
  assert.equal(s.shuffle, false);
  assert.match(s.lastError, /Premium/);
});

test('a failed transfer never schedules the follow-up play command', () => {
  const s = service();
  s.playHere();
  s.requests[0].reply(200, { devices: [{ id: 'local-id', name: 'Omafy' }] });
  s.requests[1].reply(0);
  assert.equal(s.playAfterTransfer.running, false);
  assert.match(s.lastError, /connection/);
});
