// =============================================================================
// 敢不敢揪 — Web Push 輔助橋接模組 (push_helper.js)
// 提供瀏覽器推播權限、Service Worker 註冊與 Web Push 訂閱管理
// =============================================================================

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding)
    .replace(/\-/g, '+')
    .replace(/_/g, '/');

  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);

  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

window.FindPeopleWebPush = {
  isSupported: function() {
    return (
      'serviceWorker' in navigator &&
      'PushManager' in window &&
      'Notification' in window
    );
  },

  getPermission: function() {
    if (!('Notification' in window)) return 'unsupported';
    return Notification.permission; // 'default', 'granted', 'denied'
  },

  requestPermission: async function() {
    if (!('Notification' in window)) return 'unsupported';
    try {
      const permission = await Notification.requestPermission();
      return permission;
    } catch (e) {
      console.error('requestPermission error:', e);
      return 'denied';
    }
  },

  ensureServiceWorker: async function() {
    if (!('serviceWorker' in navigator)) return null;
    try {
      const reg = await navigator.serviceWorker.register('sw.js');
      await navigator.serviceWorker.ready;
      return reg;
    } catch (e) {
      console.error('Service Worker registration failed:', e);
      return null;
    }
  },

  subscribe: async function(vapidPublicKey) {
    if (!this.isSupported()) return null;

    try {
      const reg = await this.ensureServiceWorker();
      if (!reg) return null;

      let sub = await reg.pushManager.getSubscription();
      if (!sub) {
        const options = {
          userVisibleOnly: true,
        };
        if (vapidPublicKey && vapidPublicKey.trim().length > 0) {
          options.applicationServerKey = urlBase64ToUint8Array(vapidPublicKey.trim());
        }
        sub = await reg.pushManager.subscribe(options);
      }

      const json = sub.toJSON();
      return JSON.stringify({
        endpoint: sub.endpoint,
        p256dh: json.keys ? json.keys.p256dh : '',
        auth: json.keys ? json.keys.auth : '',
        userAgent: navigator.userAgent || ''
      });
    } catch (e) {
      console.error('Web Push subscribe failed:', e);
      return null;
    }
  },

  unsubscribe: async function() {
    if (!this.isSupported()) return false;
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (sub) {
        return await sub.unsubscribe();
      }
      return true;
    } catch (e) {
      console.error('Web Push unsubscribe failed:', e);
      return false;
    }
  },

  getCurrentSubscription: async function() {
    if (!this.isSupported()) return null;
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (!sub) return null;
      const json = sub.toJSON();
      return JSON.stringify({
        endpoint: sub.endpoint,
        p256dh: json.keys ? json.keys.p256dh : '',
        auth: json.keys ? json.keys.auth : '',
        userAgent: navigator.userAgent || ''
      });
    } catch (e) {
      return null;
    }
  }
};
