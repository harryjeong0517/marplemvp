// MARPLE 서비스 워커 — 푸시 알림 + 오프라인(앱 화면 저장)
var C = 'marple-app-v1';
var SHELL = ['m.html', 'manifest.webmanifest', 'icon-192.png'];
self.addEventListener('install', function (e) { self.skipWaiting(); e.waitUntil(caches.open(C).then(function (c) { return c.addAll(SHELL); }).catch(function () {})); });
self.addEventListener('activate', function (e) { e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== C; }).map(function (k) { return caches.delete(k); })); }).then(function () { return self.clients.claim(); })); });
// 화면 파일: 인터넷 되면 항상 최신, 안 되면 저장해 둔 것
self.addEventListener('fetch', function (e) {
  var req = e.request, u = new URL(req.url);
  if (req.method !== 'GET' || u.origin !== self.location.origin || u.pathname.indexOf('/api/') === 0) return;
  var key = u.origin + u.pathname;
  e.respondWith(fetch(req).then(function (r) {
    if (r && r.ok && r.type === 'basic') { var cp = r.clone(); caches.open(C).then(function (c) { c.put(key, cp); }); }
    return r;
  }).catch(function () { return caches.match(key).then(function (m) { return m || caches.match(u.origin + u.pathname.replace(/[^\/]*$/, '') + 'm.html'); }); }));
});
self.addEventListener('push', function (e) {
  var d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'MARPLE', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'MARPLE', { body: d.body || '', icon: 'icon-192.png', badge: 'icon-192.png', tag: d.tag || undefined, renotify: !!d.tag, data: { url: d.url || 'm.html#noti' } }).then(function () {
    return self.clients.matchAll({ type: 'window' }).then(function (cs) { cs.forEach(function (c) { c.postMessage({ type: 'push' }); }); });
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || 'm.html', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    var m = cs.find(function (c) { return c.url.indexOf('m.html') >= 0; });
    if (m) { return m.focus().then(function () { return m.navigate ? m.navigate(url) : m.postMessage({ type: 'go', url: url }); }); }
    return self.clients.openWindow(url);
  }));
});
