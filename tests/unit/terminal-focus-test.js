'use strict';

// Exercise the app's per-instance policy with the shipped hterm focus methods.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const app = fs.readFileSync(path.join(root, 'app/terminal/term.js'), 'utf8');
const context = vm.createContext({
    hterm: {Terminal: function() {}, ScrollPort: function() {}},
    lib: {Storage: {Memory: function() {}}, init: async () => {}},
    window: {},
});
for (const [type, filename] of [
    ['ScrollPort', 'hterm_scrollport.js'],
    ['Terminal', 'hterm_terminal.js'],
]) {
    const vendor = fs.readFileSync(path.join(root, 'deps/libapps/hterm/js', filename), 'utf8');
    const marker = `hterm.${type}.prototype.focus = function`;
    const start = vendor.indexOf(marker);
    assert.notEqual(start, -1, `missing vendor ${type}.focus`);
    const end = vendor.indexOf('\n};', start);
    assert.notEqual(end, -1, `missing end of vendor ${type}.focus`);
    vm.runInContext(vendor.slice(start, end + 3), context);
}
vm.runInContext(app, context);

function makeTerminal() {
    const terminal = new context.hterm.Terminal();
    const scrollPort = new context.hterm.ScrollPort();
    const events = [];
    let defaultScrolls = 0;
    const element = name => {
        const node = {
            ownerDocument: {},
            focus(options) {
                assert.equal(this, node, `${name} focus receiver`);
                events.push({name, options});
                if (!options || options.preventScroll !== true) defaultScrolls++;
            },
        };
        // Focus is deliberately already held: retry must still invoke both
        // DOM focus methods to let the native keyboard reopen.
        node.ownerDocument.activeElement = node;
        return node;
    };
    scrollPort.iframe_ = element('iframe');
    scrollPort.screen_ = element('screen');
    scrollPort.publish = function(name) {
        assert.equal(this, scrollPort, 'publish receiver');
        assert.equal(name, 'focus');
        events.push({name: 'publish'});
        return 'publish return must not escape focus';
    };
    terminal.scrollPort_ = scrollPort;
    return {terminal, scrollPort, events, defaultScrolls: () => defaultScrolls};
}

function assertFocusSequence(events, count, prevented) {
    assert.deepEqual(events.map(event => event.name),
        Array.from({length: count}, () => ['iframe', 'screen', 'publish']).flat());
    for (const event of events.filter(event => event.name !== 'publish')) {
        if (prevented) {
            assert.equal(event.options.preventScroll, true);
            assert.deepEqual(Object.keys(event.options), ['preventScroll']);
        } else {
            assert.equal(event.options, undefined);
        }
    }
}

// The actual vendor method permits browser scrolling on both DOM focus calls.
const original = makeTerminal();
assert.equal(original.terminal.focus(), undefined);
assert.equal(original.terminal.focus(), undefined);
assertFocusSequence(original.events, 2, false);
assert.equal(original.defaultScrolls(), 4, 'negative control permits four default scrolls');

const vendorFocus = context.hterm.ScrollPort.prototype.focus;
const fixed = makeTerminal();
context.preventScrollOnFocus(fixed.terminal);
assert.equal(Object.hasOwn(fixed.scrollPort, 'focus'), true);
assert.equal(context.hterm.ScrollPort.prototype.focus, vendorFocus, 'vendor prototype stays intact');
assert.equal(original.scrollPort.focus, vendorFocus, 'other instances stay intact');
assert.equal(fixed.terminal.focus(), undefined);
assert.equal(fixed.terminal.focus(), undefined);
assertFocusSequence(fixed.events, 2, true);
assert.equal(fixed.defaultScrolls(), 0);

// Preserve the vendor's exception order as well as its undefined return value.
const interrupted = makeTerminal();
context.preventScrollOnFocus(interrupted.terminal);
const failure = new Error('focus failed');
interrupted.scrollPort.iframe_.focus = () => { throw failure; };
assert.throws(() => interrupted.terminal.focus(), error => error === failure);
assert.equal(interrupted.events.length, 0, 'screen focus and publish must not follow failed iframe focus');

// Run the actual onload entry point and prove installation precedes decorate,
// including any initial focus that decoration may trigger.
async function checkInitialization() {
    const initialized = makeTerminal();
    const OriginalTerminal = context.hterm.Terminal;
    context.hterm.Terminal = function() { return initialized.terminal; };
    context.hterm.Terminal.prototype = OriginalTerminal.prototype;
    const host = {};
    context.document = {getElementById: id => {
        assert.equal(id, 'terminal');
        return host;
    }};
    initialized.terminal.getPrefs = () => ({set() {}});
    initialized.terminal.realizeHeight_ = function() {};
    initialized.terminal.decorate = function(node) {
        assert.equal(node, host);
        assert.equal(Object.hasOwn(this.scrollPort_, 'focus'), true);
        assert.equal(this.focus(), undefined);
    };
    // A browser exposes window properties as globals; the vm needs this bridge.
    Object.defineProperty(context, 'term', {get: () => context.window.term});
    await context.window.onload();
    assert.equal(context.window.term, initialized.terminal);
    assertFocusSequence(initialized.events, 1, true);
    assert.equal(initialized.defaultScrolls(), 0);
}

checkInitialization().then(() => {
    console.log('terminal focus: vendor negative control, repeated focus, and initialization policy passed');
}).catch(error => {
    console.error(error);
    process.exitCode = 1;
});
