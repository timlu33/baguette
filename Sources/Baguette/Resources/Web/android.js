// android.js — the Android page at /android/<serial>.
//
// Owns the DOM and the socket; every decision about what to send lives
// in android-control.js. The video is the phone's own H.264 re-wrapped
// as the AVCC envelope frame-decoder.js already plays, so the paint
// loop is the simulator's: StreamSession.
(function () {
  'use strict';

  const C = window.AndroidControl;
  const serial = C && C.serialFromPath(location.pathname);
  if (!serial) return;

  const $ = (id) => document.getElementById(id);
  const canvas = $('screen');
  const ime = $('ime');
  const overlay = $('overlay');

  // --- Stream options (remembered per browser) ------------------------
  const STORAGE_KEY = 'baguette.android.stream';
  const DEFAULTS = { maxSize: 1600, bitrate: 8000000, fps: 60 };

  function loadOptions() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
      return Object.assign({}, DEFAULTS, saved);
    } catch { return Object.assign({}, DEFAULTS); }
  }
  function saveOptions(options) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(options)); } catch { /* private mode */ }
  }

  const options = loadOptions();
  $('optSize').value = String(options.maxSize);
  $('optRate').value = String(options.bitrate);
  $('optFps').value = String(options.fps);

  // --- Status / overlay -----------------------------------------------
  function setStatus(text, kind) {
    $('state').textContent = text;
    $('dot').className = 'dot' + (kind ? ' ' + kind : '');
  }

  function showOverlay(title, text, { spinner = false, retry = false } = {}) {
    $('overlayTitle').textContent = title;
    $('overlayText').textContent = text;
    $('spinner').hidden = !spinner;
    $('retry').hidden = !retry;
    overlay.hidden = false;
  }

  function hideOverlay() {
    overlay.hidden = true;
    canvas.hidden = false;
  }

  // --- Connection -----------------------------------------------------
  let session = null;
  let live = false;
  let wanted = true;          // false once the page is being left
  let retries = 0;
  let retryTimer = null;
  let refused = false;        // the server said no: don't loop on it

  function connect(restart) {
    clearTimeout(retryTimer);
    refused = false;
    if (session) { const old = session; session = null; old.stop(); }
    live = false;
    setStatus('Connecting…');
    $('fps').textContent = '';
    if (!window.FrameDecoder || !window.FrameDecoder.isHardwareAvailable()) {
      setStatus('Unsupported browser', 'down');
      showOverlay('This browser cannot play the stream',
        'Android streaming needs WebCodecs (Chrome, Edge or Safari 16.4+).');
      return;
    }
    if (!live) {
      showOverlay('Starting the stream…',
        'The first start pushes the scrcpy server to the phone and takes a few seconds.',
        { spinner: true });
    }

    const url = C.streamURL(location, serial, {
      maxSize: options.maxSize, bitrate: options.bitrate, fps: options.fps,
      restart: !!restart,
    });
    const s = new window.StreamSession({
      udid: serial,
      format: 'avcc',
      url,
      canvas,
      onSize: () => {},
      onFps: (fps) => { if (live) $('fps').textContent = fps + ' fps'; },
      onLog: (message, isError) => { if (isError) console.warn('[android]', message); },
      onText: (envelope) => {
        if (envelope && envelope.ok === false) {
          refused = true;
          setStatus('Unavailable', 'down');
          showOverlay('Could not stream this phone', envelope.error || 'The server refused the stream.',
            { retry: true });
          return true;
        }
        return false;
      },
      onPaint: () => {
        if (live) return;
        live = true;
        retries = 0;
        setStatus('Live', 'live');
        document.title = (deviceName || 'Android') + ' — Baguette';
        hideOverlay();
        canvas.focus({ preventScroll: true });
      },
      onClose: () => {
        if (!wanted || session !== s || refused) return;
        live = false;
        setStatus('Disconnected', 'down');
        if (retries < 3) {
          retries++;
          showOverlay('Reconnecting…', 'The stream dropped.', { spinner: true });
          retryTimer = setTimeout(() => connect(false), 1500);
        } else {
          showOverlay('Disconnected', 'The phone or the server went away. Check the cable and `adb devices`.',
            { retry: true });
        }
      },
    });
    session = s;
    s.start();
  }

  function send(envelope) {
    return !!(envelope && session && session.send && session.send(envelope));
  }

  // --- Pointer input --------------------------------------------------
  const slots = new C.PointerSlots();
  const pinches = new Map();  // browser pointer id → its mirrored second finger's slot

  function frameSize() { return { width: canvas.width, height: canvas.height }; }

  function pointOf(event) {
    return C.framePoint(canvas.getBoundingClientRect(), canvas.width, canvas.height,
      event.clientX, event.clientY);
  }

  canvas.addEventListener('contextmenu', (e) => e.preventDefault());

  canvas.addEventListener('pointerdown', (e) => {
    if (!live || !canvas.width) return;
    if (e.pointerType === 'mouse' && e.button !== 0) {
      // scrcpy's mouse mapping: right = Back, middle = Home.
      if (e.button === 2) send(C.NAV.back);
      if (e.button === 1) send(C.NAV.home);
      e.preventDefault();
      return;
    }
    const slot = slots.claim(e.pointerId);
    if (slot === null) return;
    canvas.setPointerCapture(e.pointerId);
    ime.focus({ preventScroll: true });
    const point = pointOf(e);
    send(C.pointerEnvelope('down', slot, point, frameSize(), e.pointerType === 'pen' ? e.pressure : 1));
    if (e.pointerType === 'mouse' && e.altKey) {
      const second = slots.claim(-e.pointerId - 1);   // a synthetic id, never a browser one
      if (second !== null) {
        pinches.set(e.pointerId, second);
        send(C.pointerEnvelope('down', second, C.mirrorPoint(point, canvas.width, canvas.height), frameSize()));
      }
    }
    e.preventDefault();
  });

  canvas.addEventListener('pointermove', (e) => {
    const slot = slots.slotOf(e.pointerId);
    if (slot === null || !live) return;
    const point = pointOf(e);
    send(C.pointerEnvelope('move', slot, point, frameSize(), e.pointerType === 'pen' ? e.pressure : 1));
    const second = pinches.get(e.pointerId);
    if (second !== undefined) {
      send(C.pointerEnvelope('move', second, C.mirrorPoint(point, canvas.width, canvas.height), frameSize()));
    }
  });

  function lift(e) {
    const slot = slots.slotOf(e.pointerId);
    if (slot === null) return;
    const point = pointOf(e);
    send(C.pointerEnvelope('up', slot, point, frameSize()));
    slots.release(e.pointerId);
    const second = pinches.get(e.pointerId);
    if (second !== undefined) {
      send(C.pointerEnvelope('up', second, C.mirrorPoint(point, canvas.width, canvas.height), frameSize()));
      slots.release(-e.pointerId - 1);
      pinches.delete(e.pointerId);
    }
  }
  canvas.addEventListener('pointerup', lift);
  canvas.addEventListener('pointercancel', lift);

  canvas.addEventListener('wheel', (e) => {
    if (!live) return;
    e.preventDefault();
    send(C.wheelEnvelope(e, canvas.height));
  }, { passive: false });

  // --- Keyboard / text ------------------------------------------------
  // Focus lives on a hidden input so the browser's own paste and IME
  // composition work; the canvas only hands focus over.
  canvas.addEventListener('focus', () => ime.focus({ preventScroll: true }));

  document.addEventListener('keydown', (e) => {
    const target = e.target;
    if (target && target !== ime && target !== canvas && target !== document.body) return;
    if (!live) return;
    const envelope = C.keyEnvelope(e);
    if (envelope && send(envelope)) e.preventDefault();
  });

  ime.addEventListener('compositionend', (e) => {
    send(C.textEnvelope(e.data));
    ime.value = '';
  });

  ime.addEventListener('input', (e) => {
    // A character that arrived as text and not as a key press (a dead
    // key, an on-screen keyboard, a pasted emoji) is typed whole.
    if (e.isComposing) return;
    if (e.inputType === 'insertText' || e.inputType === 'insertFromPaste') {
      if (e.data && !/^[\x20-\x7e]$/.test(e.data)) send(C.textEnvelope(e.data));
    }
    ime.value = '';
  });

  document.addEventListener('paste', (e) => {
    const text = e.clipboardData && e.clipboardData.getData('text');
    if (text && send(C.textEnvelope(text))) e.preventDefault();
  });

  // --- Buttons --------------------------------------------------------
  document.querySelectorAll('[data-act]').forEach((button) => {
    button.addEventListener('click', () => {
      send(C.NAV[button.dataset.act]);
      ime.focus({ preventScroll: true });
    });
  });

  $('shot').addEventListener('click', () => {
    const link = document.createElement('a');
    link.href = '/android/' + encodeURIComponent(serial) + '/screenshot.png';
    link.download = 'android-' + new Date().toISOString().replace(/[:.]/g, '-') + '.png';
    document.body.appendChild(link);
    link.click();
    link.remove();
  });

  function optionChanged() {
    options.maxSize = Number($('optSize').value);
    options.bitrate = Number($('optRate').value);
    options.fps = Number($('optFps').value);
    saveOptions(options);
    retries = 0;
    connect(true);   // scrcpy fixes these at start: a new server is the only way to change them
  }
  ['optSize', 'optRate', 'optFps'].forEach((id) => $(id).addEventListener('change', optionChanged));

  $('retry').addEventListener('click', () => { retries = 0; connect(true); });

  window.addEventListener('beforeunload', () => {
    wanted = false;
    if (session) session.stop();
  });

  // --- Identity -------------------------------------------------------
  let deviceName = '';
  $('serial').textContent = serial;
  fetch('/android.json', { cache: 'no-store' })
    .then((r) => r.json())
    .then((json) => {
      const device = (json.connected || []).find((d) => d.serial === serial);
      if (device) {
        deviceName = device.name;
        $('name').textContent = device.name;
        document.title = device.name + ' — Baguette';
      }
    })
    .catch(() => {});

  connect(false);
})();
