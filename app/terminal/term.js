hterm.defaultStorage = new lib.Storage.Memory();
window.onload = async function() {
    await lib.init();
    window.term = new hterm.Terminal();
    preventScrollOnFocus(term);
    preservePartialScrollbackOnGrow(term);

    // make everything invisible so as to not be embarrassing
    term.getPrefs().set('background-color', 'transparent');
    term.getPrefs().set('foreground-color', 'transparent');
    term.getPrefs().set('cursor-color', 'transparent');

    term.getPrefs().set('terminal-encoding', 'iso-2022');
    term.getPrefs().set('enable-resize-status', false);
    term.getPrefs().set('copy-on-select', false);
    term.getPrefs().set('enable-clipboard-notice', false);
    term.getPrefs().set('user-css-text', termCss);
    term.getPrefs().set('screen-padding-size', 4);
    // Creating and preloading the <audio> element for this sometimes hangs WebKit on iOS 16 for some reason. Can be most easily reproduced by resetting a simulator and starting the app. System logs show Fig hanging while trying to do work.
    term.getPrefs().set('audible-bell-sound', '');

    term.onTerminalReady = onTerminalReady;
    term.decorate(document.getElementById('terminal'));
};

function preventScrollOnFocus(terminal) {
    // Native code owns keyboard and viewport positioning. Keep every focus
    // attempt so a dismissed keyboard can reopen, without browser scrolling.
    terminal.scrollPort_.focus = function() {
        this.iframe_.focus({preventScroll: true});
        this.screen_.focus({preventScroll: true});
        this.publish('focus');
    };
}

// hterm only pulls scrollback into a growing screen when it can fill the
// entire growth. Restore the available rows first, then let it add blanks.
// Keep this on the instance: alternate-screen resizing retains hterm behavior.
function preservePartialScrollbackOnGrow(terminal) {
    const realizeHeight = terminal.realizeHeight_;
    terminal.realizeHeight_ = function(rowCount) {
        const height = this.screen_.getHeight();
        const historyCount = this.scrollbackRows_.length;
        if (this.screen_ === this.primaryScreen_ && historyCount > 0 &&
            rowCount - height > historyCount) {
            realizeHeight.call(this, height + historyCount);
        }
        return realizeHeight.call(this, rowCount);
    };
}

// Native code installs this recorder only for an explicitly enabled diagnostic
// build. Merely loading term.js adds no trace listeners, observers, or timers.
// The bridge accepts numbers and null only; terminal content is never read.
function createNumericViewportTrace(terminal, hostWindow) {
    let installedScreen = null;
    let run = null;
    let tapSequence = 0;
    const passiveCapture = {passive: true, capture: true};
    const get = (read) => {
        try { return read(); } catch (_) { return null; }
    };
    const number = (read) => {
        const value = get(read);
        return typeof value === 'number' && Number.isFinite(value) ? value : null;
    };
    const now = () => number(() => hostWindow.performance.now() / 1000);
    const integer = value => Number.isSafeInteger(value) && value > 0;

    function snapshot() {
        const port = get(() => terminal.scrollPort_);
        const iframe = get(() => port.iframe_);
        const screen = get(() => port.screen_);
        const rows = get(() => port.rowNodes_);
        const innerWindow = get(() => iframe.contentWindow);
        const activeScreen = get(() => terminal.screen_);
        const primaryScreen = get(() => terminal.primaryScreen_);
        const viewport = win => {
            const vv = get(() => win.visualViewport);
            return ['offsetTop', 'pageTop', 'height', 'scale'].map(key => number(() => vv[key]));
        };
        const rect = element => {
            const value = get(() => element.getBoundingClientRect());
            return ['x', 'y', 'width', 'height'].map(key => number(() => value[key]));
        };
        return [
            number(() => hostWindow.innerWidth), number(() => hostWindow.innerHeight),
            number(() => hostWindow.scrollY),
            number(() => hostWindow.document.documentElement.scrollTop),
            ...viewport(hostWindow),
            number(() => innerWindow.innerWidth), number(() => innerWindow.innerHeight),
            number(() => innerWindow.scrollY),
            number(() => innerWindow.document.documentElement.scrollTop),
            ...viewport(innerWindow), ...rect(iframe), ...rect(screen), ...rect(rows),
            number(() => screen.scrollTop), number(() => screen.scrollHeight),
            number(() => screen.clientHeight), number(() => port.getTopRowIndex()),
            number(() => port.visibleRowCount), number(() => port.characterSize.height),
            number(() => terminal.screenSize.width), number(() => terminal.screenSize.height),
            number(() => terminal.scrollbackRows_.length),
            activeScreen && primaryScreen ? (activeScreen === primaryScreen ? 1 : 0) : null,
            number(() => parseFloat(rows.style.top)),
        ];
    }

    function post(kind, requestId, seq, event, t, x, y, mark) {
        try {
            hostWindow.webkit.messageHandlers.viewportTrace.postMessage({
                kind, requestId, seq, event, t, x, y, mark, v: snapshot(),
            });
            return true;
        } catch (_) {
            return false;
        }
    }

    function cleanup(owner) {
        if (run !== owner) return;
        run = null; // Queued callbacks must become harmless before teardown.
        if (owner.raf !== null) get(() => hostWindow.cancelAnimationFrame(owner.raf));
        if (owner.timer !== null) get(() => hostWindow.clearTimeout(owner.timer));
        for (const [target, type, listener] of owner.listeners)
            get(() => target.removeEventListener(type, listener, passiveCapture));
        if (owner.observer) get(() => owner.observer.disconnect());
    }

    function finish(owner, includeStop = true) {
        if (run !== owner) return;
        const t = now();
        if (includeStop && t !== null && t <= owner.deadline && owner.count < owner.maxRows) {
            owner.count++;
            post(2, owner.id, owner.count, 11, t, null, null, 0);
        }
        cleanup(owner);
    }

    function emit(owner, event, mark = 0) {
        if (run !== owner) return false;
        const t = now();
        if (t === null || t > owner.deadline || owner.count >= owner.maxRows) {
            finish(owner, false);
            return false;
        }
        owner.count++;
        if (!post(2, owner.id, owner.count, event, t, null, null, mark)) {
            cleanup(owner);
            return false;
        }
        // Reserve the final row for a stop marker where the budget permits it.
        if (owner.count >= Math.max(1, owner.maxRows - 1)) finish(owner);
        return run === owner;
    }

    function sample(owner, event, mark = 0) {
        if (run !== owner) return;
        // Keep native Will/Did identifiers even when a browser event has already
        // scheduled this frame's follow-up sample. Other bursts coalesce.
        if (owner.raf !== null && event !== 10) return;
        if (!emit(owner, event, mark) || owner.raf !== null) return;
        owner.raf = hostWindow.requestAnimationFrame(() => {
            if (run !== owner) return;
            owner.raf = null;
            emit(owner, 9);
        });
    }

    function selected(doc) {
        try {
            const selection = doc.getSelection();
            return selection && selection.rangeCount !== 0 && !selection.isCollapsed;
        } catch (_) {
            return true; // Do not capture taps if selection state is unavailable.
        }
    }

    function tap(event) {
        if (!installedScreen || run || event.isTrusted !== true || selected(hostWindow.document) ||
            selected(get(() => installedScreen.ownerDocument))) return;
        const t = now();
        if (t === null) return;
        tapSequence = tapSequence < Number.MAX_SAFE_INTEGER ? tapSequence + 1 : 1;
        post(1, 0, tapSequence, 1, t,
            number(() => event.clientX), number(() => event.clientY), 0);
    }

    return {
        install() {
            if (installedScreen) return true;
            const screen = get(() => terminal.scrollPort_.screen_);
            if (!screen || typeof screen.addEventListener !== 'function') return false;
            try { screen.addEventListener('mousedown', tap, passiveCapture); }
            catch (_) { return false; }
            installedScreen = screen;
            return true;
        },
        start(requestId, durationMs, maxRows) {
            if (!installedScreen || !integer(requestId) ||
                typeof durationMs !== 'number' || !Number.isFinite(durationMs) || durationMs <= 0 ||
                !integer(maxRows)) return null;
            if (run) return run.id === requestId ? run.begin : null;
            const begin = now();
            if (begin === null) return null;
            const owner = {
                id: requestId, begin, deadline: begin + Math.min(durationMs, 60000) / 1000,
                maxRows: Math.min(maxRows, 512), count: 0, raf: null, timer: null,
                listeners: [], observer: null,
            };
            run = owner;
            try {
                const listen = (target, type, event) => {
                    if (!target || typeof target.addEventListener !== 'function') return;
                    const listener = () => sample(owner, event);
                    target.addEventListener(type, listener, passiveCapture);
                    owner.listeners.push([target, type, listener]);
                };
                const port = get(() => terminal.scrollPort_);
                const iframe = get(() => port.iframe_);
                const innerWindow = get(() => iframe.contentWindow);
                const targets = [...new Set([installedScreen, hostWindow, innerWindow])];
                for (const target of targets) {
                    listen(target, 'focus', 3);
                    listen(target, 'blur', 12);
                    listen(target, 'scroll', 4);
                    listen(target, 'resize', 5);
                }
                for (const type of ['scroll', 'resize']) {
                    listen(get(() => hostWindow.visualViewport), type, 6);
                    listen(get(() => innerWindow.visualViewport), type, 7);
                }
                if (typeof hostWindow.ResizeObserver === 'function') {
                    owner.observer = new hostWindow.ResizeObserver(() => sample(owner, 8));
                    for (const element of new Set([iframe, installedScreen, get(() => port.rowNodes_)])) {
                        if (element) owner.observer.observe(element);
                    }
                }
                owner.timer = hostWindow.setTimeout(() => finish(owner),
                    Math.min(durationMs, 60000));
                sample(owner, 2);
            } catch (_) {
                cleanup(owner);
                return null;
            }
            return begin;
        },
        mark(nativeEvent) {
            if (run && integer(nativeEvent)) sample(run, 10, nativeEvent);
        },
        stop(requestId) {
            if (run && run.id === requestId) finish(run);
        },
        uninstall() {
            if (run) finish(run);
            if (installedScreen)
                get(() => installedScreen.removeEventListener('mousedown', tap, passiveCapture));
            installedScreen = null;
        },
    };
}

var termCss = `
x-screen {
    background: transparent !important;
    overflow: hidden !important;
    -webkit-tap-highlight-color: transparent;
}
x-row {
  text-rendering: optimizeLegibility;
  font-variant-ligatures: normal;
}
.uri-node {
  text-decoration: underline;
}
`;

function onTerminalReady() {

// Shorthand for JS -> native IPC
const native = new Proxy({}, {
    get(obj, prop) {
        return (...args) => {
            if (args.length == 0)
                args = null;
            else if (args.length == 1)
                args = args[0];
            webkit.messageHandlers[prop].postMessage(args);
        };
    },
});

// Functions for native -> JS
window.exports = {};

let numericViewportTrace = null;
exports.installNumericViewportTrace = () => {
    if (!numericViewportTrace) numericViewportTrace = createNumericViewportTrace(term, window);
    return numericViewportTrace.install();
};
exports.startNumericViewportTrace = (requestId, durationMs, maxRows) =>
    numericViewportTrace ? numericViewportTrace.start(requestId, durationMs, maxRows) : null;
exports.markNumericViewportTrace = (nativeEvent) => {
    if (numericViewportTrace) numericViewportTrace.mark(nativeEvent);
};
exports.stopNumericViewportTrace = (requestId) => {
    if (numericViewportTrace) numericViewportTrace.stop(requestId);
};
exports.uninstallNumericViewportTrace = () => {
    if (numericViewportTrace) numericViewportTrace.uninstall();
    numericViewportTrace = null;
};

term.io.push();
term.reset();

let oldProps = {};
function syncProp(name, value) {
    if (oldProps[name] !== value)
        native.propUpdate(name, value);
}
let decoder = new TextDecoder();
exports.write = (data) => {
    term.io.writeUTF16(decoder.decode(lib.codec.stringToCodeUnitArray(data)));
    syncProp('applicationCursor', term.keyboard.applicationCursor);
};
term.io.sendString = term.io.onVTKeyStroke = (data) => {
    native.sendInput(data);
};

// hterm size updates native size
term.io.onTerminalResize = () => native.resize();
exports.getSize = () => [term.screenSize.width, term.screenSize.height];

// selection, copying
term.scrollPort_.screen_.contentEditable = false;
term.blur();
term.focus();
exports.copy = () => term.copySelectionToClipboard();

// focus
// This listener blocks blur events that come in because the webview has lost first responder
term.scrollPort_.screen_.addEventListener('blur', (e) => {
    if (e.target.ownerDocument.activeElement == e.target) {
        e.stopPropagation();
    }
}, {capture: true});
term.scrollPort_.screen_.addEventListener('mousedown', (e) => {
    // Taps while there is a selection should be left to the selection view
    if ((document.getSelection().rangeCount != 0) &&
        (!document.getSelection().isCollapsed)) return;
    native.focus();
});
exports.setFocused = (focus) => {
    if (focus)
        term.focus();
    else
        term.blur();
};
term.scrollPort_.screen_.addEventListener('focus', (e) => native.syncFocus());

// scrolling
// Disable hterm builtin touch scrolling
term.scrollPort_.onTouch = (e) => {
    // Convince hterm that we called preventDefault() and that it shouldn't do more handling, but don't actually call it because that would break text selection
    Object.defineProperty(e, 'defaultPrevented', {value: true});
};
// Scroll to bottom wrapper
exports.scrollToBottom = () => term.scrollEnd();
// Set scroll position
exports.newScrollTop = (y) => {
    // two lines instead of one because the value you read out of scrollTop can be different from the value you write into it
    term.scrollPort_.screen_.scrollTop = y;
    lastScrollTop = term.scrollPort_.screen_.scrollTop;
};

// Send scroll height and position to native code
let lastScrollHeight, lastScrollTop;
function syncScroll() {
    const scrollHeight = parseFloat(term.scrollPort_.scrollArea_.style.height);
    if (scrollHeight != lastScrollHeight)
        native.newScrollHeight(scrollHeight);
    lastScrollHeight = scrollHeight;

    const scrollTop = term.scrollPort_.screen_.scrollTop;
    if (scrollTop != lastScrollTop)
        native.newScrollTop(scrollTop);
    lastScrollTop = scrollTop;
}

const realSyncScrollHeight = hterm.ScrollPort.prototype.syncScrollHeight;
hterm.ScrollPort.prototype.syncScrollHeight = function() {
    realSyncScrollHeight.call(this);
    syncScroll();
};
term.scrollPort_.screen_.addEventListener('scroll', syncScroll);

exports.updateStyle = ({foregroundColor, backgroundColor, fontFamily, fontSize, colorPaletteOverrides, blinkCursor, cursorShape}) => {
    term.getPrefs().set('background-color', backgroundColor);
    term.getPrefs().set('foreground-color', foregroundColor);
    term.getPrefs().set('cursor-color', foregroundColor);
    term.getPrefs().set('font-family', fontFamily);
    term.getPrefs().set('font-size', fontSize);
    term.getPrefs().set('color-palette-overrides', colorPaletteOverrides);
    term.getPrefs().set('cursor-blink', blinkCursor);
    term.getPrefs().set('cursor-shape', cursorShape);
};

exports.getCharacterSize = () => {
    return [term.scrollPort_.characterSize.width, term.scrollPort_.characterSize.height];
};

exports.clearScrollback = () => term.clearScrollback();
exports.setUserGesture = () => term.accessibilityReader_.hasUserGesture = true;

hterm.openUrl = (url) => native.openLink(url);

native.load();
native.syncFocus();

}
