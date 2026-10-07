'use strict';

self.addEventListener('install', function () {
  console.log('PWA Service Worker: install');
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  console.log('PWA Service Worker: activate');
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', function (event) {
  var path = '';
  try { path = new URL(event.request.url).pathname; } catch (e) { return; }
  if (path.indexOf('/auth') !== 0) return;
  event.respondWith(fetch(event.request, { cache: 'no-store' }));
});
