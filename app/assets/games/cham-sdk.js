/* Chạm Game SDK, apiLevel 1. Host (Flutter) tiêm qua /__cham/sdk.js. */
(function () {
  var handlers = [], readyCb = null, initData = null, pending = [];
  function post(o) {
    var s = JSON.stringify(o);
    if (window.ChamHost && window.ChamHost.postMessage) window.ChamHost.postMessage(s);
    else pending.push(s);
  }
  window.ChamBridge = {
    _recv: function (s) {
      var m = typeof s === 'string' ? JSON.parse(s) : s;
      if (m.t === 'init') { initData = m.data; if (readyCb) readyCb(initData); }
      else if (m.t === 'msg') handlers.forEach(function (h) { try { h(m.data, m.ch); } catch (e) {} });
    }
  };
  window.Cham = {
    apiLevel: 1,
    // cb({me:0|1, peer:{name}, seed:int, mode, apiLevel}); gọi khi hai máy đã sẵn sàng
    init: function (cb) { readyCb = cb; post({ t: 'ready' }); if (initData) cb(initData); },
    // ch: 'reliable' (<=8KB) | 'fast' (<=1KB, có thể mất)
    send: function (data, ch) { post({ t: 'send', ch: ch || 'reliable', data: data }); },
    onMessage: function (h) { handlers.push(h); },
    end: function (result) { post({ t: 'end', result: result }); },
    time: function () { return Date.now(); }
  };
})();
