'use strict';

// Load the app's actual exported bridge in a browser-shaped VM. The fake clock
// and event targets exercise ownership and cleanup without a device or WebKit.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../app/terminal/term.js'), 'utf8');

function harness() {
    const messages = [];
    const nativeCalls = [];
    const targets = [];
    const observers = [];
    const rafs = new Map();
    const timers = new Map();
    let time = 1000;
    let identifier = 0;
    let geometryReads = 0;
    let privateReads = 0;
    let mutations = 0;
    let terminalFocus = 0;
    let terminalBlur = 0;

    function target(name) {
        const listeners = [];
        const value = {
            name, listeners,
            addEventListener(type, listener, options) { listeners.push({type, listener, options}); },
            removeEventListener(type, listener, options) {
                const i = listeners.findIndex(entry => entry.type === type &&
                    entry.listener === listener && entry.options === options);
                assert.notEqual(i, -1, `${name}: remove must match an installed listener`);
                listeners.splice(i, 1);
            },
            dispatch(type, overrides = {}) {
                const event = {target: value, isTrusted: true, clientX: 100, clientY: 200,
                    stopPropagation() {}, preventDefault() { mutations++; }, ...overrides};
                for (const entry of [...listeners].sort((a, b) =>
                    Number(Boolean(b.options && b.options.capture)) -
                    Number(Boolean(a.options && a.options.capture)))) {
                    if (entry.type === type) entry.listener(event);
                }
            },
        };
        targets.push(value);
        return value;
    }
    function secretProperties(value) {
        for (const key of ['textContent', 'innerText', 'innerHTML', 'title', 'URL']) {
            Object.defineProperty(value, key, {get() {
                privateReads++;
                throw new Error(`private property ${key} must not be read`);
            }});
        }
        return value;
    }
    function document(scrollTop) {
        const selection = {rangeCount: 0, isCollapsed: true,
            toString() { privateReads++; throw new Error('selection text must not be read'); }};
        return Object.assign(secretProperties({}), {
            documentElement: secretProperties({scrollTop}),
            getSelection: () => selection, selection,
        });
    }
    function geometry(value, rect) {
        secretProperties(value);
        value.getBoundingClientRect = () => {
            geometryReads++;
            return {x: rect[0], y: rect[1], width: rect[2], height: rect[3]};
        };
        return value;
    }
    const outerDocument = document(5);
    const innerDocument = document(10);
    const host = Object.assign(target('outer window'), {
        innerWidth: 1000, innerHeight: 600, scrollY: 4, document: outerDocument,
        visualViewport: Object.assign(target('outer viewport'),
            {offsetTop: 6, pageTop: 7, height: 8, scale: 1}),
        performance: {now() { return time; }},
        requestAnimationFrame(callback) { const id = ++identifier; rafs.set(id, callback); return id; },
        cancelAnimationFrame(id) { rafs.delete(id); },
        setTimeout(callback, delay) {
            const id = ++identifier; timers.set(id, {callback, at: time + delay}); return id;
        },
        clearTimeout(id) { timers.delete(id); },
        ResizeObserver: class {
            constructor(callback) { this.callback = callback; this.elements = []; observers.push(this); }
            observe(element) { this.elements.push(element); }
            disconnect() { this.disconnected = true; }
        },
    });
    const inner = Object.assign(target('iframe window'), {
        innerWidth: 900, innerHeight: 500, scrollY: 9, document: innerDocument,
        visualViewport: Object.assign(target('iframe viewport'),
            {offsetTop: 11, pageTop: 12, height: 13, scale: 2}),
    });
    const iframe = geometry(target('iframe'), [14, 15, 16, 17]);
    iframe.contentWindow = inner;
    const screen = geometry(target('screen'), [18, 19, 20, 21]);
    screen.ownerDocument = innerDocument;
    screen.scrollHeight = 27;
    screen.clientHeight = 28;
    let scrollTop = 26;
    Object.defineProperty(screen, 'scrollTop', {
        get() { return scrollTop; }, set(value) { mutations++; scrollTop = value; },
    });
    const rows = geometry(target('rows'), [22, 23, 24, 25]);
    rows.style = {top: '35px'};
    const primary = {};
    const term = {
        scrollPort_: {iframe_: iframe, screen_: screen, rowNodes_: rows,
            scrollArea_: {style: {height: '400px'}},
            getTopRowIndex: () => 29, visibleRowCount: 30, characterSize: {height: 31}},
        screen_: primary, primaryScreen_: primary, screenSize: {width: 32, height: 33},
        scrollbackRows_: new Array(34),
        io: {push() {}, writeUTF16() {}}, keyboard: {}, reset() {},
        blur() { terminalBlur++; }, focus() { terminalFocus++; },
    };
    secretProperties(term);
    const handlers = new Proxy({}, {get(_, name) {
        return {postMessage(value) {
            if (name === 'viewportTrace') messages.push(value);
            else nativeCalls.push(name);
        }};
    }});
    host.webkit = {messageHandlers: handlers};
    const context = vm.createContext({
        window: host, document: outerDocument, term, webkit: host.webkit, TextDecoder,
        hterm: {Terminal: function() {}, ScrollPort: function() {}},
        lib: {Storage: {Memory: function() {}}, codec: {}},
    });
    context.hterm.ScrollPort.prototype.syncScrollHeight = function() {};
    Object.defineProperty(context, 'exports', {get: () => host.exports});
    vm.runInContext(source, context);
    context.onTerminalReady();
    const baseListeners = new Map(targets.map(value => [value, value.listeners.length]));
    const baseFocus = terminalFocus;
    const baseBlur = terminalBlur;

    return {
        exports: host.exports, host, inner, screen, iframe, rows, term, targets, observers,
        messages, nativeCalls, rafs, timers, outerDocument, innerDocument, baseListeners,
        reads: () => ({geometryReads, privateReads}),
        assertUnchanged() {
            assert.equal(mutations, 0, 'recorder must not focus, scroll, or prevent input');
            assert.equal(terminalFocus, baseFocus);
            assert.equal(terminalBlur, baseBlur);
            assert.equal(privateReads, 0, 'recorder must not read terminal or selection text');
        },
        assertRunClean(installed = true) {
            assert.equal(rafs.size, 0, 'all RAFs must be canceled');
            assert.equal(timers.size, 0, 'all timers must be cleared');
            for (const value of targets) {
                assert.equal(value.listeners.length,
                    baseListeners.get(value) + Number(installed && value === screen), value.name);
            }
            for (const observer of observers) assert.equal(observer.disconnected, true);
        },
        frame() {
            const pending = [...rafs.values()]; rafs.clear();
            for (const callback of pending) callback(time);
        },
        advance(ms, runTimers = true) {
            time += ms;
            if (!runTimers) return;
            for (const [id, timer] of [...timers]) {
                if (timer.at <= time) { timers.delete(id); timer.callback(); }
            }
        },
    };
}

function schema(messages) {
    const keys = ['kind', 'requestId', 'seq', 'event', 't', 'x', 'y', 'mark', 'v'].sort();
    for (const message of messages) {
        assert.deepEqual(Object.keys(message).sort(), keys);
        for (const [key, value] of Object.entries(message)) {
            if (key === 'v') {
                assert.equal(value.length, 39);
                for (const number of value)
                    assert.ok(number === null || typeof number === 'number' && Number.isFinite(number));
            } else {
                assert.ok(value === null || typeof value === 'number' && Number.isFinite(value));
            }
        }
        assert.ok(Number.isSafeInteger(message.seq) && message.seq > 0);
        assert.equal(message.mark === 0 || message.event === 10, true);
    }
}

// Default-off entry points do not inspect geometry or add even one trace hook.
{
    const h = harness();
    assert.equal(h.exports.startNumericViewportTrace(1, 60000, 512), null);
    h.exports.markNumericViewportTrace(1);
    h.exports.stopNumericViewportTrace(1);
    h.exports.uninstallNumericViewportTrace();
    assert.deepEqual(h.reads(), {geometryReads: 0, privateReads: 0});
    assert.equal(h.messages.length, 0);
    assert.equal(h.observers.length, 0);
    for (const target of h.targets)
        assert.equal(target.listeners.length, target === h.screen ? 4 : 0,
            'only the pre-existing terminal listeners may exist by default');
    h.assertRunClean(false);
    h.assertUnchanged();
}

// Invalid native arguments cannot create even a partial run. Setup failures
// clean previously registered hooks without escaping into normal terminal code.
{
    const h = harness();
    h.exports.installNumericViewportTrace();
    for (const args of [[0, 60000, 512], [1, Infinity, 512], [1, '60000', 512],
        [1, 0, 512], [1, 1, 0], [1, 1, 1.5], [NaN, 1, 1]])
        assert.equal(h.exports.startNumericViewportTrace(...args), null);
    h.assertRunClean();
    h.host.ResizeObserver = class { constructor() { throw new Error('observer unavailable'); } };
    assert.equal(h.exports.startNumericViewportTrace(1, 60000, 512), null);
    assert.equal(h.messages.length, 0);
    h.assertRunClean();
    h.host.ResizeObserver = class {
        constructor(callback) { this.callback = callback; h.observers.push(this); }
        observe() { throw new Error('disposed element'); }
        disconnect() { this.disconnected = true; }
    };
    assert.equal(h.exports.startNumericViewportTrace(2, 60000, 512), null);
    h.assertRunClean();
    h.exports.uninstallNumericViewportTrace();
    h.assertRunClean(false);
    h.assertUnchanged();
}

// If the native bridge disappears, the recorder tears itself down. Normal
// terminal handlers and a later opt-in run can still work independently.
{
    const h = harness();
    h.exports.installNumericViewportTrace();
    const bridge = h.host.webkit;
    h.host.webkit = null;
    assert.equal(h.exports.startNumericViewportTrace(1, 60000, 512), 1);
    assert.equal(h.messages.length, 0);
    h.assertRunClean();
    h.host.webkit = bridge;
    assert.equal(h.exports.startNumericViewportTrace(2, 60000, 512), 1);
    assert.equal(h.messages.length, 1);
    h.exports.stopNumericViewportTrace(2);
    h.assertRunClean();
    h.exports.uninstallNumericViewportTrace();
    h.assertRunClean(false);
    h.assertUnchanged();
}

// The installed tap hook is passive and captures only real selection-free taps.
{
    const h = harness();
    assert.equal(h.exports.installNumericViewportTrace(), true);
    assert.equal(h.exports.installNumericViewportTrace(), true);
    assert.equal(h.screen.listeners.length, h.baseListeners.get(h.screen) + 1);
    const listener = h.screen.listeners.at(-1);
    assert.equal(listener.options.passive, true);
    assert.equal(listener.options.capture, true);
    assert.equal(h.reads().geometryReads, 0, 'installation itself must not sample');
    h.screen.dispatch('mousedown', {isTrusted: false});
    h.outerDocument.selection.rangeCount = 1;
    h.outerDocument.selection.isCollapsed = false;
    h.screen.dispatch('mousedown');
    h.outerDocument.selection.isCollapsed = true;
    h.innerDocument.selection.rangeCount = 1;
    h.innerDocument.selection.isCollapsed = false;
    h.screen.dispatch('mousedown');
    assert.equal(h.messages.length, 0);
    h.innerDocument.selection.isCollapsed = true;
    h.screen.dispatch('mousedown');
    assert.equal(h.messages.length, 1);
    assert.equal(h.messages[0].kind, 1);
    assert.equal(h.messages[0].requestId, 0);
    assert.equal(h.messages[0].event, 1);
    assert.equal(h.messages[0].x, 100);
    assert.equal(h.messages[0].y, 200);
    assert.deepEqual(Array.from(h.messages[0].v), [
        1000, 600, 4, 5, 6, 7, 8, 1, 900, 500, 9, 10, 11, 12, 13, 2,
        14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32, 33, 34, 1, 35,
    ]);
    schema(h.messages);
    h.exports.uninstallNumericViewportTrace();
    listener.listener({isTrusted: true, clientX: 1, clientY: 2});
    assert.equal(h.messages.length, 1, 'late tap cannot sample after uninstall');
    h.assertRunClean(false);
    h.assertUnchanged();
}

// Exactly one run owns listeners/deadline; native marks keep their identifiers
// while ordinary event bursts share a single next-RAF sample.
{
    const h = harness();
    h.exports.installNumericViewportTrace();
    assert.equal(h.exports.startNumericViewportTrace(41, 60000, 512), 1);
    const listenerCount = h.targets.reduce((sum, value) => sum + value.listeners.length, 0);
    h.advance(100);
    assert.equal(h.exports.startNumericViewportTrace(41, 60000, 512), 1);
    assert.equal(h.exports.startNumericViewportTrace(42, 60000, 512), null);
    assert.equal(h.targets.reduce((sum, value) => sum + value.listeners.length, 0), listenerCount);
    assert.equal(h.timers.size, 1);
    assert.equal([...h.timers.values()][0].at, 61000, 'duplicate start must not extend deadline');
    assert.equal(h.observers.length, 1);
    assert.deepEqual(h.observers[0].elements, [h.iframe, h.screen, h.rows]);
    for (let i = 0; i < 20; i++) h.screen.dispatch('scroll');
    h.screen.dispatch('mousedown');
    assert.equal(h.messages.length, 1, 'event bursts and taps do not compete with active owner');
    h.exports.markNumericViewportTrace(7);
    h.exports.markNumericViewportTrace(8);
    h.exports.markNumericViewportTrace('SECRET');
    h.exports.markNumericViewportTrace(NaN);
    assert.equal(h.rafs.size, 1);
    assert.deepEqual(h.messages.map(message => [message.event, message.mark]), [[2, 0], [10, 7], [10, 8]]);
    h.frame();
    assert.equal(h.messages.at(-1).event, 9);
    const events = [
        [h.screen, 'focus', 3], [h.screen, 'blur', 12],
        [h.screen, 'scroll', 4], [h.host, 'resize', 5], [h.inner, 'scroll', 4],
        [h.host.visualViewport, 'resize', 6], [h.inner.visualViewport, 'scroll', 7],
    ];
    for (const [target, type, code] of events) {
        target.dispatch(type);
        assert.equal(h.messages.at(-1).event, code);
        h.frame();
    }
    h.observers[0].callback();
    assert.equal(h.messages.at(-1).event, 8);
    const lateRAF = [...h.rafs.values()][0];
    const lateTimer = [...h.timers.values()][0].callback;
    const lateObserver = h.observers[0].callback;
    h.exports.stopNumericViewportTrace(42);
    assert.equal(h.messages.at(-1).event, 8, 'other owner cannot stop a run');
    h.exports.stopNumericViewportTrace(41);
    assert.equal(h.messages.at(-1).event, 11);
    h.assertRunClean();
    const count = h.messages.length;
    lateRAF(); lateTimer(); lateObserver();
    assert.equal(h.messages.length, count);
    assert.equal(h.exports.startNumericViewportTrace(42, 1000, 10), 1.1);
    lateRAF(); lateTimer(); lateObserver();
    assert.equal(h.messages.length, count + 1, 'old callbacks cannot mutate a new run');
    h.exports.uninstallNumericViewportTrace();
    schema(h.messages);
    h.assertRunClean(false);
    h.assertUnchanged();
}

// Both independent budgets terminate their run, including a delayed timer and
// an event that arrives after the deadline before that timer gets CPU time.
for (const viaTimer of [false, true]) {
    const h = harness();
    h.exports.installNumericViewportTrace();
    h.exports.startNumericViewportTrace(1, 999999, 999999);
    assert.equal([...h.timers.values()][0].at, 61000);
    const count = h.messages.length;
    h.advance(60001, viaTimer);
    if (!viaTimer) h.exports.markNumericViewportTrace(1);
    assert.equal(h.messages.length, count, 'nothing may be posted past the local deadline');
    h.assertRunClean();
    h.exports.uninstallNumericViewportTrace();
    h.assertUnchanged();
}
{
    const h = harness();
    h.exports.installNumericViewportTrace();
    h.exports.startNumericViewportTrace(1, 60000, 999999);
    for (let i = 0; i < 600; i++) h.exports.markNumericViewportTrace(1);
    assert.equal(h.messages.length, 512);
    assert.equal(h.messages.at(-1).event, 11);
    assert.deepEqual(h.messages.map(message => message.seq), Array.from({length: 512}, (_, i) => i + 1));
    schema(h.messages);
    h.assertRunClean();
    h.exports.uninstallNumericViewportTrace();
    h.assertUnchanged();
}

// Missing/hostile geometry is null, never coerced to strings or nonfinite JSON;
// every optional read is isolated so one unavailable viewport does not abort it.
{
    const h = harness();
    h.exports.installNumericViewportTrace();
    h.host.innerWidth = 'SECRET';
    h.host.scrollY = Infinity;
    h.host.visualViewport = null;
    h.inner.innerHeight = NaN;
    h.rows.style.top = 'SECRET';
    h.screen.getBoundingClientRect = () => { throw new Error('unavailable'); };
    h.term.primaryScreen_ = null;
    h.exports.startNumericViewportTrace(1, 10, 2);
    assert.equal(h.messages.length, 2);
    for (const index of [0, 2, 4, 5, 6, 7, 9, 20, 21, 22, 23, 37, 38])
        assert.equal(h.messages[0].v[index], null, `unavailable field ${index}`);
    assert.equal(JSON.stringify(h.messages).includes('SECRET'), false);
    schema(h.messages);
    h.assertRunClean();
    h.exports.uninstallNumericViewportTrace();
    h.assertUnchanged();
}

console.log('terminal numeric viewport trace: default-off, privacy schema, ownership, budgets, and cleanup passed');
