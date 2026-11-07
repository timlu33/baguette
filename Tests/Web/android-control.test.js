'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'android-control.js'
);

function control() {
  return loadBrowserModule(MODULE_PATH).AndroidControl;
}

test('a click on the canvas lands on the matching pixel of the frame', () => {
  const rect = { left: 100, top: 50, width: 360, height: 640 };
  // Half the CSS size on screen → twice as many pixels in the frame.
  assert.deepEqual(control().framePoint(rect, 720, 1280, 280, 370), { x: 360, y: 640 });
});

test('a drag that leaves the canvas keeps pressing its edge', () => {
  const rect = { left: 0, top: 0, width: 100, height: 200 };
  assert.deepEqual(control().framePoint(rect, 720, 1280, -30, 999), { x: 0, y: 1279 });
  assert.deepEqual(control().framePoint(rect, 720, 1280, 999, -30), { x: 719, y: 0 });
});

test('a collapsed canvas maps to the origin instead of dividing by zero', () => {
  assert.deepEqual(control().framePoint({ left: 0, top: 0, width: 0, height: 0 }, 720, 1280, 5, 5), { x: 0, y: 0 });
});

test('the second finger of a pinch sits opposite the first through the frame centre', () => {
  assert.deepEqual(control().mirrorPoint({ x: 100, y: 200 }, 720, 1280), { x: 619, y: 1079 });
});

test('a pointer envelope carries its id, position, frame size and pressure', () => {
  const env = control().pointerEnvelope('down', 1, { x: 10, y: 20 }, { width: 720, height: 1280 });
  assert.deepEqual(env, { type: 'pointer-down', id: 1, x: 10, y: 20, width: 720, height: 1280, pressure: 1 });
});

test('a lifted pointer carries no pressure unless one is given', () => {
  const up = control().pointerEnvelope('up', 0, { x: 1, y: 2 }, { width: 3, height: 4 });
  assert.equal(up.pressure, 0);
  const pen = control().pointerEnvelope('move', 0, { x: 1, y: 2 }, { width: 3, height: 4 }, 0.4);
  assert.equal(pen.pressure, 0.4);
});

test('a keydown becomes a key envelope with its modifiers named as the server spells them', () => {
  const env = control().keyEnvelope({ code: 'KeyA', shiftKey: true, altKey: true });
  assert.deepEqual(env, { type: 'key', code: 'KeyA', modifiers: ['shift', 'option'] });
});

test('a plain keydown carries no modifiers field', () => {
  assert.deepEqual(control().keyEnvelope({ code: 'Enter' }), { type: 'key', code: 'Enter' });
});

test('keys the server cannot press are not sent', () => {
  assert.equal(control().keyEnvelope({ code: 'F5' }), null);
  assert.equal(control().keyEnvelope({ code: 'Delete' }), null);
  assert.equal(control().keyEnvelope({}), null);
});

test('keys typed while composing text are left to the composition', () => {
  assert.equal(control().keyEnvelope({ code: 'KeyA', isComposing: true }), null);
  assert.equal(control().keyEnvelope({ code: 'KeyA', keyCode: 229 }), null);
});

test('a paste shortcut is left to the paste event so Unicode survives', () => {
  assert.equal(control().keyEnvelope({ code: 'KeyV', metaKey: true }), null);
  assert.equal(control().keyEnvelope({ code: 'KeyV', ctrlKey: true }), null);
});

test('browser shortcuts are not stolen from the browser', () => {
  assert.equal(control().keyEnvelope({ code: 'KeyR', metaKey: true }), null);
  assert.equal(control().keyEnvelope({ code: 'KeyW', ctrlKey: true }), null);
});

test('typed text is sent whole, and empty text is not sent', () => {
  assert.deepEqual(control().textEnvelope('你好'), { type: 'text', text: '你好' });
  assert.equal(control().textEnvelope(''), null);
});

test('a wheel notch in lines is converted to pixels', () => {
  const env = control().wheelEnvelope({ deltaX: 0, deltaY: 3, deltaMode: 1 }, 1280);
  assert.deepEqual(env, { type: 'scroll', deltaX: 0, deltaY: 120 });
});

test('a wheel page is a frame height', () => {
  const env = control().wheelEnvelope({ deltaX: 0, deltaY: 1, deltaMode: 2 }, 1280);
  assert.equal(env.deltaY, 1280);
});

test('a pixel wheel is passed through as it is', () => {
  const env = control().wheelEnvelope({ deltaX: 7, deltaY: -12, deltaMode: 0 }, 1280);
  assert.deepEqual(env, { type: 'scroll', deltaX: 7, deltaY: -12 });
});

test('navigation buttons name the envelope the server understands', () => {
  const { NAV } = control();
  assert.deepEqual(NAV.back, { type: 'nav', action: 'back' });
  assert.deepEqual(NAV.power, { type: 'button', button: 'power' });
  assert.deepEqual(NAV.volumeUp, { type: 'button', button: 'volume-up' });
});

test('the stream URL encodes a serial that contains a colon', () => {
  const url = control().streamURL({ protocol: 'http:', host: 'mac.local:8421' }, '192.168.1.9:5555');
  assert.equal(url, 'ws://mac.local:8421/android/192.168.1.9%3A5555/stream');
});

test('the stream URL is secure when the page is', () => {
  const url = control().streamURL({ protocol: 'https:', host: 'h' }, 'abc');
  assert.ok(url.startsWith('wss://h/android/abc/stream'));
});

test('the stream URL carries only the options that were given', () => {
  const url = control().streamURL({ protocol: 'http:', host: 'h' }, 'abc', { maxSize: 1280, restart: true });
  assert.equal(url, 'ws://h/android/abc/stream?maxSize=1280&restart=1');
});

test('the serial comes out of the page path and nothing else does', () => {
  assert.equal(control().serialFromPath('/android/192.168.1.9%3A5555'), '192.168.1.9:5555');
  assert.equal(control().serialFromPath('/android'), null);
  assert.equal(control().serialFromPath('/simulators/abc'), null);
  assert.equal(control().serialFromPath('/android/a/b'), null);
});

test('a mouse is always finger zero and freed slots are reused lowest first', () => {
  const slots = new (control().PointerSlots)();
  assert.equal(slots.claim(11), 0);
  assert.equal(slots.claim(12), 1);
  assert.equal(slots.claim(11), 0);
  slots.release(11);
  assert.equal(slots.claim(13), 0);
  assert.equal(slots.slotOf(12), 1);
  assert.equal(slots.slotOf(99), null);
});

test('more fingers than the digitizer tracks are refused', () => {
  const slots = new (control().PointerSlots)();
  for (let i = 0; i < control().MAX_POINTERS; i++) assert.notEqual(slots.claim(i), null);
  assert.equal(slots.claim(999), null);
});
