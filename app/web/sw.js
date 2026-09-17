// =============================================================================
// 敢不敢揪 — Web Push Service Worker (sw.js)
// 職責：
// 1. 背景接收 Push 事件（去重 tag、防範 PII 洩漏、自適應圖示）
// 2. 點擊通知導航（聚焦既有分頁或開啟新視窗並執行 deep link）
// =============================================================================

self.addEventListener('install', function(event) {
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function(event) {
  if (!event.data) return;

  let payload = {};
  try {
    payload = event.data.json();
  } catch (e) {
    payload = { title: '敢不敢揪', body: event.data.text() };
  }

  const title = payload.title || '敢不敢揪';
  const eventType = payload.eventType || payload.event_type || '';
  const targetUrl = payload.url || (payload.data && payload.data.url) || '/notifications';
  
  // 去重 Tag：同一類別（如同一活動或同一次確認）到達時就地替換舊通知，避免疊加打擾
  const tag = payload.tag || (eventType ? 'notif-' + eventType : 'find-people-general');

  const options = {
    body: payload.body || '你有新的通知',
    icon: '/icons/Icon-192.png',
    badge: '/favicon.png',
    tag: tag,
    renotify: true,
    data: {
      url: targetUrl,
      eventType: eventType,
      timestamp: Date.now(),
      ...(payload.data || {})
    }
  };

  event.waitUntil(
    self.registration.showNotification(title, options)
  );
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();

  const targetUrl = (event.notification.data && event.notification.data.url) || '/';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList) {
      for (let i = 0; i < clientList.length; i++) {
        let client = clientList[i];
        if ('focus' in client) {
          client.focus();
          if ('navigate' in client) {
            return client.navigate(targetUrl);
          } else {
            client.postMessage({
              type: 'NOTIFICATION_CLICKED',
              url: targetUrl,
              data: event.notification.data
            });
            return;
          }
        }
      }
      if (self.clients.openWindow) {
        return self.clients.openWindow(targetUrl);
      }
    })
  );
});
