#!/usr/bin/env node
// Node harness for the todo-spa SPA, in the style of monad's own
// wasm/web/spa_smoke.mjs: drives the real mount/dispatch/tick loop over a
// stub DOM, using the vendored `web.js`/`web_runtime.js` loader unmodified.
// A stubbed `fetch` stands in for the running todo-backend and `localStorage`
// for the browser's cache. Usage:
//   node web/smoke.mjs [app.wasm]
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// The generated boot statically imports the hash-pinned loader copies and
// re-exports them; in Node its `document` guard skips the mount.
import { imports, host } from "./boot.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = process.argv[2] ?? join(here, "app.wasm");

class FakeNode {
  constructor(nodeType, tagName) {
    this.nodeType = nodeType;
    this.tagName = tagName;
    this.childNodes = [];
    this.attrs = {};
    this.listeners = {};
    this.parentNode = null;
    this._text = "";
    this.value = "";
  }
  appendChild(child) {
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  insertBefore(child, before) {
    const at = before ? this.childNodes.indexOf(before) : -1;
    child.parentNode = this;
    if (at < 0) this.childNodes.push(child);
    else this.childNodes.splice(at, 0, child);
    return child;
  }
  removeChild(child) {
    const at = this.childNodes.indexOf(child);
    if (at >= 0) this.childNodes.splice(at, 1);
    child.parentNode = null;
    return child;
  }
  replaceChild(next, old) {
    const at = this.childNodes.indexOf(old);
    if (at >= 0) this.childNodes[at] = next;
    next.parentNode = this;
    old.parentNode = null;
    return old;
  }
  setAttribute(name, value) {
    this.attrs[name] = value;
    // The loader writes controlled-input values as attributes; mirror it so
    // `event_str(5)` (target.value) sees the current text.
    if (name === "value") this.value = value;
  }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
  }
  removeAttribute(name) {
    delete this.attrs[name];
  }
  addEventListener(event, handler) {
    (this.listeners[event] ||= []).push(handler);
  }
  removeEventListener(event, handler) {
    this.listeners[event] = (this.listeners[event] || []).filter((h) => h !== handler);
  }
  fire(event, evt) {
    for (const handler of this.listeners[event] || []) handler(evt);
  }
  get textContent() {
    if (this.nodeType === 3) return this._text;
    return this.childNodes.map((c) => c.textContent).join("");
  }
  set textContent(value) {
    this.childNodes = [];
    this._text = value;
    // Real DOM replaces an element's children with a single text node
    // (which is what the getter above reads back via childNodes); without
    // this, setting textContent on a non-text node (e.g. the injected
    // <style>) silently reads back empty.
    if (this.nodeType !== 3 && value) {
      const t = new FakeNode(3, "#text");
      t.nodeValue = value;
      t.parentNode = this;
      this.childNodes.push(t);
    }
  }
  get nodeValue() {
    return this._text;
  }
  set nodeValue(value) {
    this._text = value;
  }
}

const head = new FakeNode(1, "HEAD");
const body = new FakeNode(1, "BODY");
const app = new FakeNode(1, "DIV");
app.setAttribute("id", "app");
body.appendChild(app);
globalThis.document = {
  body,
  head,
  querySelector(sel) {
    return sel === "#app" ? app : sel === "body" ? body : sel === "head" ? head : null;
  },
  createElement(tag) {
    return new FakeNode(1, tag.toUpperCase());
  },
  createTextNode(text) {
    const n = new FakeNode(3, "#text");
    n.nodeValue = text;
    return n;
  },
  createComment(text) {
    const n = new FakeNode(8, "#comment");
    n.nodeValue = text;
    return n;
  },
};

const store = new Map();
globalThis.localStorage = {
  getItem(k) {
    return store.has(k) ? store.get(k) : null;
  },
  setItem(k, v) {
    store.set(k, v);
  },
};

// ── stub backend ───────────────────────────────────────────────────────
// GET /api/todos and POST /api/actions both return the full list, matching
// handlers.mo. The action shapes are `Action.to_json`'s.
let serverTodos = [
  { id: 1, title: "Learn Monad", done: false, notes: "", tags: [], group: null, status: "todo",
    subtasks: [{ id: 1, title: "read the docs", done: false }] },
  { id: 2, title: "Build a todo app", done: false, notes: "", tags: ["urgent"], group: "Work",
    status: "todo", subtasks: [] },
];

function maxId() {
  return serverTodos.reduce((m, t) => Math.max(m, t.id), 0);
}

function maxSubtaskId() {
  return serverTodos.reduce(
    (m, t) => Math.max(m, ...t.subtasks.map((s) => s.id)), 0);
}

function applyAction(action) {
  switch (action.type) {
    case "add": {
      serverTodos.push({
        id: maxId() + 1, title: action.title, done: false, notes: "",
        tags: [], group: null, status: "todo", subtasks: [],
      });
      return;
    }
    case "toggle":
      serverTodos = serverTodos.map((t) => {
        if (t.id !== action.id) return t;
        const done = !t.done;
        return { ...t, done, status: done ? "done" : "todo" };
      });
      return;
    case "delete":
      serverTodos = serverTodos.filter((t) => t.id !== action.id);
      return;
    case "edit":
      serverTodos = serverTodos.map((t) => t.id === action.id
        ? { ...t, title: action.title, notes: action.notes,
            group: action.group ?? null, tags: action.tags ?? [] }
        : t);
      return;
    case "add_subtask": {
      const sid = maxSubtaskId() + 1;
      serverTodos = serverTodos.map((t) => t.id === action.id
        ? { ...t, subtasks: [...t.subtasks, { id: sid, title: action.title, done: false }] }
        : t);
      return;
    }
    case "toggle_subtask":
      serverTodos = serverTodos.map((t) => ({
        ...t,
        subtasks: t.subtasks.map((s) => s.id === action.id ? { ...s, done: !s.done } : s),
      }));
      return;
    case "delete_subtask":
      serverTodos = serverTodos.map((t) => ({
        ...t, subtasks: t.subtasks.filter((s) => s.id !== action.id),
      }));
      return;
    case "clear_completed":
      serverTodos = serverTodos.filter((t) => !t.done);
      return;
    case "set_status":
      serverTodos = serverTodos.map((t) => t.id === action.id
        ? { ...t, status: action.status, done: action.status === "done" }
        : t);
      return;
    default:
      return; // render
  }
}

globalThis.fetch = async (url, options = {}) => {
  if (url === "/api/actions") {
    applyAction(JSON.parse(options.body || "{}"));
  }
  const text = JSON.stringify(serverTodos);
  return { ok: true, status: 200, arrayBuffer: async () => new TextEncoder().encode(text).buffer };
};

// ── frame loop ─────────────────────────────────────────────────────────
// The loader only dispatches the animation-frame subscription inside
// `start_ticks`; pump one queued callback per `settle` step so the frame
// `Msg.poll` runs immediately before `oak_tick`.
const frames = [];
globalThis.requestAnimationFrame = (cb) => {
  frames.push(cb);
  return frames.length;
};

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

// The app's view structure changes shape (nav/footer/settings wrappers),
// so queries walk the whole tree by class/tag rather than hardcoding
// childNodes indices.
function walk(node, acc = []) {
  acc.push(node);
  for (const c of node.childNodes) walk(c, acc);
  return acc;
}

function hasClass(node, cls) {
  return (node.attrs.class || "").split(" ").includes(cls);
}

function byClass(cls) {
  return walk(app).filter((n) => hasClass(n, cls));
}

function byTag(tag) {
  return walk(app).filter((n) => n.tagName === tag);
}

function root() {
  return app.childNodes[0];
}

function todoList() {
  return byClass("todo");
}

function buttonByText(text) {
  return byTag("BUTTON").find((b) => b.textContent === text) || null;
}

function deleteButtonFor(li) {
  const main = walk(li).find((n) => hasClass(n, "todo-main"));
  return main.childNodes[1];
}

function settingRowButton(label) {
  const row = byClass("setting-row").find((r) => r.childNodes[0]?.textContent === label);
  return row ? row.childNodes[1] : null;
}

// A synthetic DOM event with the bits the loader reads.
function domEvent(type, target, extra = {}) {
  return { type, target, preventDefault() {}, stopPropagation() {}, ...extra };
}

function dataTransfer() {
  const data = {};
  return {
    data,
    effectAllowed: "",
    dropEffect: "",
    types: [],
    files: [],
    setData(mime, text) { data[mime] = text; },
    getData(mime) { return data[mime] || ""; },
  };
}

function click(node) {
  node.fire("click", domEvent("click", node));
}

function typeInto(input, text) {
  input.value = text;
  input.fire("input", domEvent("input", input));
}

async function settle(instance, count) {
  for (let i = 0; i < count; i++) {
    const cb = frames.shift();
    if (cb) cb(globalThis.performance ? globalThis.performance.now() : Date.now());
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, imports);
host.bind(instance);
host.set_root("#app");

instance.exports.oak_mount();
if (app.childNodes.length !== 1) fail(`oak_mount should append exactly one root node, got ${app.childNodes.length}`);
host.start_ticks(instance);

const injectedStyle = head.childNodes.find((n) => n.tagName === "STYLE");
if (!injectedStyle) fail("oak_mount did not inject a <style> node into <head>");
if (!injectedStyle.textContent.includes("--accent")) fail("the injected <style> node does not contain View.css");
console.log("ok: View.css is injected into <head> on mount");

await settle(instance, 10);
if (todoList().length !== 2) fail(`expected 2 todos after the initial load, got ${todoList().length}`);
if (byTag("FORM").length !== 0) fail("the SPA rendered a <form> on the tasks page");
console.log("ok: initial load rendered 2 todos (animation-frame subscription)");

const toggleBtn = buttonByText("Learn Monad");
if (!toggleBtn) fail('could not find the "Learn Monad" toggle button');
click(toggleBtn);
await settle(instance, 10);
const firstLi = todoList()[0];
if (!hasClass(firstLi, "done")) fail("toggle did not mark the item done in the DOM");
if (!serverTodos[0].done) fail("toggle did not sync to the stub server");
console.log("ok: toggle updated the DOM and synced to the server");

// Settings tab / dark mode / hide-completed: all pure clicks, no reload.
click(buttonByText("Settings"));
await settle(instance, 2);
if (!byClass("settings-tab").length) fail("switching to Settings did not render the settings tab");
if (root().attrs["data-theme"] !== "light") fail(`expected light theme by default, got ${root().attrs["data-theme"]}`);
click(settingRowButton("Dark mode"));
await settle(instance, 2);
if (root().attrs["data-theme"] !== "dark") fail("toggling dark mode did not flip the data-theme attribute");
console.log("ok: settings tab renders and dark-mode toggle flips the theme attribute, no reload");

click(settingRowButton("Hide completed"));
click(buttonByText("Tasks"));
await settle(instance, 2);
if (todoList().length !== 1) fail(`expected hide-completed to filter the done item, got ${todoList().length} visible`);
console.log("ok: hide-completed filters the done item out of the rendered list");

click(buttonByText("Settings"));
await settle(instance, 2); // the tab renders on the next tick
click(settingRowButton("Hide completed")); // toggle back off so the rest of the scenarios see every item
click(buttonByText("Tasks"));
await settle(instance, 2);
if (todoList().length !== 2) fail("un-hiding completed did not restore the full list");

// Subtask toggle/delete: pure typed click handlers.
const subtaskToggleBtn = buttonByText("read the docs");
if (!subtaskToggleBtn) fail('could not find the "read the docs" subtask button');
click(subtaskToggleBtn);
await settle(instance, 10);
if (!serverTodos[0].subtasks[0].done) fail("subtask toggle did not sync to the stub server");
console.log("ok: subtask toggle synced to the server with no reload");

const subtaskRow = byClass("subtask-row")[0];
click(subtaskRow.childNodes[1]);
await settle(instance, 10);
if (serverTodos[0].subtasks.length !== 0) fail("subtask delete did not sync to the stub server");
console.log("ok: subtask delete synced to the server with no reload");

// New-task page: the SPA owns the controls (controlled input + Html.on click).
click(buttonByText("+ New"));
await settle(instance, 2);
if (byTag("FORM").length !== 0) fail("the new-task page rendered a <form>");
const addForm = byClass("add-form")[0];
if (!addForm) fail("the new-task page did not render the add form");
if (byClass("todo").length) fail("the new-task page should not also render the task list");
const addInput = addForm.childNodes[0];
typeInto(addInput, "From the SPA form");
await settle(instance, 2);
const addButton = walk(addForm).find((b) => b.tagName === "BUTTON" && b.textContent === "Add");
if (!addButton) fail("the add control has no Add button");
if (addButton.attrs.type !== "button") fail("the add button is not type=button");
click(addButton);
await settle(instance, 10);
if (!serverTodos.find((t) => t.title === "From the SPA form")) fail("the SPA add control did not reach the server");
if (!buttonByText("From the SPA form")) fail("the imported todo was not rendered after the add");
console.log("ok: SPA add control (on_input + Html.on click) created a todo and returned to the list");

// Edit page: prefilled controlled fields, then Enter submits.
click(buttonByText("Edit"));
await settle(instance, 2);
if (todoList().length) fail("the edit page should not also render the task list");
if (byTag("FORM").length !== 0) fail("the edit page rendered a <form>");
const editForm = byClass("edit-form")[0];
const editTitle = byTag("INPUT").find((n) => n.attrs.name === "title");
if (!editForm || !editTitle) fail("the edit page did not render its form");
if (editTitle.attrs.value !== "Learn Monad") fail(`the edit page did not prefill the title, got ${editTitle.attrs.value}`);
typeInto(editTitle, "Edited in the SPA");
const editNotes = byTag("TEXTAREA")[0];
if (!editNotes) fail("the edit page did not render the notes textarea");
editNotes.value = "edited notes";
editNotes.fire("change", domEvent("change", editNotes));
await settle(instance, 2);
const saveButton = walk(editForm).find((b) => b.tagName === "BUTTON" && b.textContent === "Save");
if (!saveButton) fail("the edit control has no Save button");
if (saveButton.attrs.type !== "button") fail("the edit Save button is not type=button");
// Enter in the title input submits through `Html.on "keydown"`.
editTitle.fire("keydown", domEvent("keydown", editTitle, { key: "Enter" }));
await settle(instance, 10);
if (serverTodos[0].title !== "Edited in the SPA") fail("the SPA edit control did not reach the server");
if (serverTodos[0].notes !== "edited notes") fail("the SPA edit control did not carry the notes field");
if (!buttonByText("Edited in the SPA")) fail("the edited title was not rendered after the edit");
console.log("ok: SPA edit control prefilled, Enter-submitted title+notes, and returned to the list");

// Subtask add: the inline controls clear via the keyed generation.
const subtaskForm = byClass("subtask-add-form")[0];
const subtaskInput = subtaskForm.childNodes[0];
typeInto(subtaskInput, "a new step");
await settle(instance, 2);
const subtaskButton = walk(subtaskForm).find((b) => b.tagName === "BUTTON" && b.textContent === "+");
if (!subtaskButton) fail("the subtask control has no add button");
if (subtaskButton.attrs.type !== "button") fail("the subtask add button is not type=button");
click(subtaskButton);
await settle(instance, 10);
if (!serverTodos[0].subtasks.find((s) => s.title === "a new step")) fail("the SPA subtask control did not reach the server");
const clearedForm = byClass("subtask-add-form")[0];
if (clearedForm.childNodes[0].attrs.value !== "") fail("the subtask input was not recreated empty after a successful add");
console.log("ok: SPA subtask control added a subtask and cleared its input");

// Kanban: click moves still work. Pick a card in the To-do column so the
// forward button is present, and identify it by title (the list order is
// not the server order).
click(buttonByText("Kanban"));
await settle(instance, 2);
if (byClass("kanban-column").length !== 3) fail(`expected 3 kanban columns, got ${byClass("kanban-column").length}`);
if (!byClass("kanban-card").length) fail("the kanban board did not render any cards");
if (byTag("FORM").length !== 0) fail("the kanban page rendered a <form>");

function columnByLabel(label) {
  return byClass("kanban-column").find((c) => c.childNodes[0].textContent === label);
}

function cardTitle(card) {
  const title = walk(card).find((n) => hasClass(n, "kanban-title"));
  return title ? title.textContent : "";
}

const todoColumn = columnByLabel("To do");
const firstCard = todoColumn && walk(todoColumn).find((n) => hasClass(n, "kanban-card"));
if (!firstCard) fail("the To-do column has no card");
if (firstCard.attrs.draggable !== "true") fail("the kanban card is not draggable");
if (!(firstCard.listeners.dragstart || []).length) fail("the kanban card has no dragstart listener");
if (!(firstCard.listeners.dragend || []).length) fail("the kanban card has no dragend listener");
const firstTitle = cardTitle(firstCard);
const moveForward = walk(firstCard).find((b) => b.tagName === "BUTTON" && b.textContent === ">");
if (!moveForward) fail("could not find a forward move button on a To-do card");
if (moveForward.attrs.type !== "button") fail("the kanban move button is not type=button");
for (let p = moveForward.parentNode; p; p = p.parentNode) {
  if (p.tagName === "FORM") fail("the kanban move button is wrapped in a form");
}
click(moveForward);
await settle(instance, 10);
const movedTodo = serverTodos.find((t) => t.title === firstTitle);
if (!movedTodo || movedTodo.status !== "doing") fail(`expected "${firstTitle}" to move to "doing", got ${movedTodo && movedTodo.status}`);
console.log("ok: kanban move buttons update status locally and sync to the server, no reload");

// Kanban drag-and-drop: the card's payload carries its id; the column's drop
// handler parses it and applies set_status. Drag a To-do card onto Doing.
function cardInColumn(label, title) {
  const column = columnByLabel(label);
  return column && walk(column).find((n) => hasClass(n, "kanban-card") && cardTitle(n) === title);
}

// A cancelled drag clears the visual state and moves nothing.
const cancelCard = walk(columnByLabel("To do")).find((n) => hasClass(n, "kanban-card"));
if (!cancelCard) fail("no card in To do for the cancelled-drag test");
const cancelTitle = cardTitle(cancelCard);
const cancelStatus = serverTodos.find((t) => t.title === cancelTitle).status;
cancelCard.fire("dragstart", domEvent("dragstart", cancelCard, { dataTransfer: dataTransfer() }));
await settle(instance, 1);
const cancelDragging = cardInColumn("To do", cancelTitle);
if (!cancelDragging || !hasClass(cancelDragging, "dragging")) fail("the dragged card is not marked dragging");
const cancelNow = cardInColumn("To do", cancelTitle);
cancelNow.fire("dragend", domEvent("dragend", cancelNow));
await settle(instance, 2);
const cancelAfter = cardInColumn("To do", cancelTitle);
if (!cancelAfter || hasClass(cancelAfter, "dragging")) fail("dragend did not clear the dragging class");
if (serverTodos.find((t) => t.title === cancelTitle).status !== cancelStatus) fail("a cancelled drag changed the status");
console.log("ok: cancelling a drag clears the drag state without moving the card");

const dragCard = walk(columnByLabel("To do")).find((n) => hasClass(n, "kanban-card"));
const doingColumn = columnByLabel("Doing");
if (!dragCard || !doingColumn) fail("could not find a To-do card and the Doing column");
const dragTitle = cardTitle(dragCard);
const dt = dataTransfer();
dragCard.fire("dragstart", domEvent("dragstart", dragCard, { dataTransfer: dt }));
await settle(instance, 1);
if (dt.getData("text/plain") === "") fail("the drag payload was not set by the loader");
const sourceCard = cardInColumn("To do", dragTitle);
if (!sourceCard || !hasClass(sourceCard, "dragging")) fail("the drag source card is not marked dragging");
const hoveredColumn = columnByLabel("Doing");
hoveredColumn.fire("dragover", domEvent("dragover", hoveredColumn, { dataTransfer: dt }));
await settle(instance, 1);
if (!hasClass(columnByLabel("Doing"), "drag-over")) fail("the hovered column is not highlighted");
const dropColumn = columnByLabel("Doing");
dropColumn.fire("drop", domEvent("drop", dropColumn, { dataTransfer: dt }));
await settle(instance, 10);
const droppedTodo = serverTodos.find((t) => t.title === dragTitle);
if (!droppedTodo || droppedTodo.status !== "doing") fail(`drag-and-drop did not set "${dragTitle}" to doing, got ${droppedTodo && droppedTodo.status}`);
if (hasClass(columnByLabel("Doing"), "drag-over")) fail("the drop highlight was not cleared");
const landed = cardInColumn("Doing", dragTitle);
if (!landed || hasClass(landed, "dragging")) fail("the dragged card was not moved/cleared after the drop");
console.log("ok: kanban drag-and-drop moved a card into Doing, with drag-over feedback");

click(buttonByText("Tasks"));
await settle(instance, 2);

// Tag/group filter bar: click-only; each chip dispatches its position.
const unfiltered = todoList().length;
const workChip = byClass("filter-chip").find((n) => n.textContent === "Work");
if (!workChip) fail('could not find the "Work" group filter chip');
click(workChip);
await settle(instance, 2);
if (todoList().length !== 1) fail(`expected the group filter to leave 1 visible todo, got ${todoList().length}`);
if (!hasClass(workChip, "active")) fail("the active group filter chip should carry the active class");
const activeWorkChip = byClass("filter-chip").find((n) => n.textContent === "Work");
click(activeWorkChip); // clicking the active chip again clears the filter
await settle(instance, 2);
if (todoList().length !== unfiltered) fail(`clicking the active group filter chip again did not clear it (got ${todoList().length}, expected ${unfiltered})`);
console.log("ok: the group filter chip filters the task list and toggles off on a second click");

// Clear completed: ensure the edited todo is done, then clear. The kanban
// scenarios moved other cards around, so do not assume list order.
const editedTodo = () => serverTodos.find((t) => t.title === "Edited in the SPA");
if (!editedTodo()) fail("the edited todo disappeared before the clear-completed test");
if (!editedTodo().done) {
  const editedLi = todoList().find((li) =>
    walk(li).some((n) => hasClass(n, "title") && n.textContent === "Edited in the SPA"));
  if (!editedLi) fail("could not find the edited todo in the task list");
  click(walk(editedLi).find((n) => hasClass(n, "title")));
  await settle(instance, 10);
}
if (!editedTodo().done) fail("could not establish a done todo before clear-completed");
const expectedRemaining = serverTodos.filter((t) => !t.done).length;
click(buttonByText("Clear completed"));
await settle(instance, 10);
if (todoList().length !== expectedRemaining) fail(`expected ${expectedRemaining} todos after clear-completed, got ${todoList().length}`);
if (serverTodos.length !== expectedRemaining) fail("clear-completed did not sync to the stub server");
console.log("ok: clear-completed updated the DOM and synced to the server");

const beforeDelete = todoList().length;
click(deleteButtonFor(todoList()[0]));
await settle(instance, 10);
if (todoList().length !== beforeDelete - 1) fail(`expected ${beforeDelete - 1} todos after delete, got ${todoList().length}`);
if (serverTodos.length !== beforeDelete - 1) fail("delete did not sync to the stub server");
console.log("ok: delete updated the DOM and synced to the server");

console.log(`ok: ${wasmPath} -> typed events, subscriptions, SPA controls and kanban drag-and-drop all round-tripped with no reload and no <form>`);
