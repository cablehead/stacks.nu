// Action registry + key bindings, both authored server-side and shipped on
// `<main>` as JSON:
//
//   data-actions='{"<id>": "<js-string>", ...}'
//   data-keymap='{"<combo>": "<id>", ...}'
//
// Triggers (key press OR status-bar click) reference an action id.
// `window.actions.invoke(id)` evaluates the JS string. The action strings
// are plain JS -- typically `fetch(...)` -- so adding new behavior is just
// a matter of writing the JS server-side.
//
// Combo strings are built in fixed order: cmd, ctrl, alt, shift, then the
// key. Letters are lowercased so `shift+j` matches Shift+J without the
// upstream on-keys plugin's case-mismatch bug.

(function () {
  function comboKey(e) {
    const parts = [];
    if (e.metaKey) parts.push("cmd");
    if (e.ctrlKey) parts.push("ctrl");
    if (e.altKey) parts.push("alt");
    if (e.shiftKey) parts.push("shift");
    let k = e.key;
    if (k.length === 1 && /[a-zA-Z]/.test(k)) k = k.toLowerCase();
    if (k === " ") k = "space";
    parts.push(k.toLowerCase());
    return parts.join("+");
  }

  function readJson(name) {
    const main = document.querySelector("main");
    const raw = main && main.dataset[name];
    if (!raw) return {};
    try { return JSON.parse(raw); } catch (_) { return {}; }
  }

  window.actions = {
    invoke: function (id) {
      const js = readJson("actions")[id];
      if (js) new Function(js)();
    },
    fire: function (combo) {
      const id = readJson("keymap")[combo];
      if (id) window.actions.invoke(id);
    },
  };

  document.addEventListener("keydown", function (e) {
    const id = readJson("keymap")[comboKey(e)];
    if (!id) return;
    e.preventDefault();
    window.actions.invoke(id);
  });
})();
