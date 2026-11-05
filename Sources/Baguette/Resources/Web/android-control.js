// AndroidControl — the pure half of the Android page: coordinates,
// gesture envelopes and URLs, with no DOM and no socket, so it can be
// tested under node. `android.js` wires it to the canvas and the WS.
//
// The wire is the simulator's (docs/wire.md) plus three Android-only
// envelopes: `pointer-down|move|up` (one browser pointer, by id),
// `nav` (back / home / recents / …) and `text` (Unicode, whole).
(function () {
  'use strict';

  /** Pointers a phone's digitizer is asked to track at once. */
  const MAX_POINTERS = 10;

  // Keys the server can press: W3C KeyboardEvent.code values the HID
  // table knows (Domain/Input/Keyboard.swift). Anything else would be
  // answered with an error ack, so it is filtered here instead.
  const KEY_CODE = new RegExp(
    '^(Key[A-Z]|Digit[0-9]|Numpad([0-9]|Decimal|Divide|Multiply|Subtract|Add|Enter|Equal)' +
    '|Enter|Escape|Backspace|Tab|Space|Minus|Equal|BracketLeft|BracketRight|Backslash' +
    '|Semicolon|Quote|Backquote|Comma|Period|Slash|Arrow(Up|Down|Left|Right))$'
  );

  /**
   * A client position on the canvas as a pixel of the decoded frame.
   * `rect` is the canvas's bounding box on screen; the frame is
   * `width` × `height` pixels stretched over it. Clamped, so a drag
   * that leaves the canvas keeps pressing its edge.
   */
  function framePoint(rect, width, height, clientX, clientY) {
    const fx = rect.width > 0 ? (clientX - rect.left) / rect.width : 0;
    const fy = rect.height > 0 ? (clientY - rect.top) / rect.height : 0;
    return {
      x: Math.max(0, Math.min(width - 1, Math.round(fx * width))),
      y: Math.max(0, Math.min(height - 1, Math.round(fy * height))),
    };
  }

  /** The point opposite `point` through the frame's centre — the second
   *  finger of an Alt-drag pinch. */
  function mirrorPoint(point, width, height) {
    return {
      x: Math.max(0, Math.min(width - 1, width - 1 - point.x)),
      y: Math.max(0, Math.min(height - 1, height - 1 - point.y)),
    };
  }

  function pointerEnvelope(phase, id, point, size, pressure) {
    return {
      type: 'pointer-' + phase,
      id,
      x: point.x,
      y: point.y,
      width: size.width,
      height: size.height,
      pressure: pressure === undefined ? (phase === 'up' ? 0 : 1) : pressure,
    };
  }

  /** The `key` envelope for a keydown, or null when the browser is
   *  composing text, the key is unsupported, or Ctrl/Cmd is held — those
   *  belong to the browser (reload, close tab) and to the `paste` event,
   *  which carries pasted text with Unicode intact. */
  function keyEnvelope(event) {
    if (event.isComposing || event.keyCode === 229) return null;
    if (event.ctrlKey || event.metaKey) return null;
    if (!KEY_CODE.test(event.code || '')) return null;
    const modifiers = [];
    if (event.shiftKey) modifiers.push('shift');
    if (event.altKey) modifiers.push('option');
    const envelope = { type: 'key', code: event.code };
    if (modifiers.length) envelope.modifiers = modifiers;
    return envelope;
  }

  function textEnvelope(text) {
    return text ? { type: 'text', text } : null;
  }

  /** A wheel event as a `scroll` envelope in pixels, whatever unit the
   *  browser reported it in. */
  function wheelEnvelope(event, frameHeight) {
    const unit = event.deltaMode === 1 ? 40 : event.deltaMode === 2 ? frameHeight : 1;
    return { type: 'scroll', deltaX: event.deltaX * unit, deltaY: event.deltaY * unit };
  }

  const NAV = {
    back:          { type: 'nav', action: 'back' },
    home:          { type: 'nav', action: 'home' },
    recents:       { type: 'nav', action: 'recents' },
    notifications: { type: 'nav', action: 'notifications' },
    settings:      { type: 'nav', action: 'settings' },
    collapse:      { type: 'nav', action: 'collapse' },
    rotate:        { type: 'nav', action: 'rotate' },
    wake:          { type: 'nav', action: 'wake' },
    power:         { type: 'button', button: 'power' },
    volumeUp:      { type: 'button', button: 'volume-up' },
    volumeDown:    { type: 'button', button: 'volume-down' },
  };

  /**
   * `ws://host/android/<serial>/stream?…`. Only options that were
   * given are sent; the server clamps and defaults the rest. They take
   * effect when this connection starts the phone's session — pass
   * `restart` to replace a running one.
   */
  function streamURL(location, serial, options) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const o = options || {};
    const query = [];
    if (o.maxSize !== undefined) query.push('maxSize=' + encodeURIComponent(o.maxSize));
    if (o.bitrate !== undefined) query.push('bitrate=' + encodeURIComponent(o.bitrate));
    if (o.fps !== undefined) query.push('fps=' + encodeURIComponent(o.fps));
    if (o.restart) query.push('restart=1');
    return proto + '//' + location.host + '/android/' + encodeURIComponent(serial) + '/stream' +
      (query.length ? '?' + query.join('&') : '');
  }

  /** The serial out of `/android/<serial>`, or null on any other path. */
  function serialFromPath(pathname) {
    const parts = pathname.split('/').filter(Boolean);
    if (parts.length !== 2 || parts[0] !== 'android') return null;
    try { return decodeURIComponent(parts[1]) || null; } catch { return null; }
  }

  /**
   * Browser pointer ids → the small ids the phone's digitizer wants.
   * The lowest free slot is reused, so a mouse is always finger 0.
   */
  class PointerSlots {
    constructor() { this.byBrowserId = new Map(); }
    claim(browserId) {
      if (this.byBrowserId.has(browserId)) return this.byBrowserId.get(browserId);
      const taken = new Set(this.byBrowserId.values());
      for (let slot = 0; slot < MAX_POINTERS; slot++) {
        if (!taken.has(slot)) { this.byBrowserId.set(browserId, slot); return slot; }
      }
      return null;
    }
    slotOf(browserId) {
      return this.byBrowserId.has(browserId) ? this.byBrowserId.get(browserId) : null;
    }
    release(browserId) { this.byBrowserId.delete(browserId); }
    get size() { return this.byBrowserId.size; }
  }

  window.AndroidControl = {
    MAX_POINTERS, NAV, PointerSlots,
    framePoint, mirrorPoint, pointerEnvelope, keyEnvelope, textEnvelope,
    wheelEnvelope, streamURL, serialFromPath,
  };
})();
