'use strict';

// Exercise the shipped hterm resize implementation together with the app shim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const vendor = fs.readFileSync(path.join(root, 'deps/libapps/hterm/js/hterm_terminal.js'), 'utf8');
const app = fs.readFileSync(path.join(root, 'app/terminal/term.js'), 'utf8');
const context = vm.createContext({
    hterm: {Terminal: function() {}},
    lib: {Storage: {Memory: function() {}}},
    window: {},
});
for (const name of ['realizeSize_', 'realizeHeight_']) {
    const marker = `hterm.Terminal.prototype.${name} = function`;
    const start = vendor.indexOf(marker);
    assert.notEqual(start, -1, `missing vendor ${name}`);
    const end = vendor.indexOf('\n};', start);
    assert.notEqual(end, -1, `missing end of vendor ${name}`);
    vm.runInContext(vendor.slice(start, end + 3), context);
}
vm.runInContext(app, context);

function makeTerminal(rows, cursor, history = [], alternate = false, patched = true) {
    const terminal = new context.hterm.Terminal();
    const screen = {
        rows: [...rows],
        getHeight() { return this.rows.length; },
        popRow() { return this.rows.pop(); },
        shiftRows(n) { return this.rows.splice(0, n); },
        unshiftRows(rows) { this.rows.unshift(...rows); },
    };
    terminal.primaryScreen_ = alternate ? {} : screen;
    terminal.screen_ = screen;
    terminal.screenSize = {width: 80, height: rows.length};
    terminal.scrollbackRows_ = [...history];
    terminal.cursor = cursor;
    terminal.saveCursor = () => ({row: terminal.cursor});
    terminal.restoreCursor = saved => { terminal.cursor = saved.row; };
    terminal.getRowCount = () => terminal.scrollbackRows_.length + screen.rows.length;
    terminal.getRowText = index => [...terminal.scrollbackRows_, ...screen.rows][index].text;
    let blankId = 0;
    terminal.appendRows_ = count => {
        while (count--) screen.rows.push({text: '', blank: ++blankId});
    };
    terminal.setVTScrollRegion = () => {};
    terminal.notifications = [];
    terminal.io = {onTerminalResize_: (width, height) => terminal.notifications.push([width, height])};
    if (patched) context.preservePartialScrollbackOnGrow(terminal);
    return terminal;
}
const row = text => ({text});
const outputs = Array.from({length: 5}, (_, i) => row(`out${i}`));
const prompt = row('prompt');
const blanks = Array.from({length: 24}, () => row(''));
const initial = [...outputs, prompt, ...blanks];
function resize(terminal, height) { terminal.realizeSize_(80, height); }

// Reproduce the regression with the actual unmodified vendor implementation.
const original = makeTerminal(initial, 5, [], false, false);
resize(original, 1);
resize(original, 30);
assert.equal(original.scrollbackRows_.length, 5);
assert.equal(original.screen_.rows[0], prompt);
assert.equal(original.cursor, 0);

const fixed = makeTerminal(initial, 5);
resize(fixed, 1);
assert.deepEqual(fixed.scrollbackRows_, outputs);
resize(fixed, 30);
assert.deepEqual(fixed.screen_.rows.slice(0, 6), [...outputs, prompt]);
assert.equal(fixed.scrollbackRows_.length, 0);
assert.equal(fixed.cursor, 5);
assert.deepEqual(fixed.notifications, [[80, 1], [80, 30]]);
resize(fixed, 1);
resize(fixed, 30);
assert.deepEqual(fixed.screen_.rows.slice(0, 6), [...outputs, prompt]);
assert.equal(fixed.cursor, 5);
assert.deepEqual(fixed.notifications, [[80, 1], [80, 30], [80, 1], [80, 30]]);

// Sufficient history uses the vendor path; its remainder stays in order.
const history = [row('a'), row('b'), row('c')];
const sufficient = makeTerminal([prompt], 0, history);
resize(sufficient, 3);
assert.deepEqual(sufficient.scrollbackRows_, [history[0]]);
assert.deepEqual(sufficient.screen_.rows, [history[1], history[2], prompt]);
assert.equal(sufficient.cursor, 2);
assert.deepEqual(sufficient.notifications, [[80, 3]]);

const noHistory = makeTerminal([prompt], 0);
resize(noHistory, 3);
assert.equal(noHistory.screen_.rows[0], prompt);
assert.equal(noHistory.cursor, 0);
assert.equal(noHistory.scrollbackRows_.length, 0);
resize(noHistory, 3); // No-op must not notify.
assert.deepEqual(noHistory.notifications, [[80, 3]]);

// The alternate screen is deliberately unchanged, including its vendor behavior.
const alternate = makeTerminal([prompt], 0, history, true);
resize(alternate, 5);
assert.equal(alternate.screen_.rows[0], prompt);
assert.deepEqual(alternate.scrollbackRows_, history);
assert.equal(alternate.cursor, 0);
assert.deepEqual(alternate.notifications, [[80, 5]]);
console.log('terminal resize: vendor negative control and app regression cases passed');
