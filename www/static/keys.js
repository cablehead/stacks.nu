// One window keydown listener. Reads the active keymap from `<main>`'s
// `data-keymap` attribute on every keystroke; the SSE patch swaps that
// attribute when the projection's mode changes.
//
// keymap shape (JSON):
//   {
//     "<combo>": "<url>"                       // POST <url>, no body
//     "<combo>": {url, source}                 // POST <url>, body = el.value of `source` selector
//   }
//
// `<combo>` is built from the event in a fixed order: cmd, ctrl, alt, shift,
// then the key. Letters are lowercased so `shift+j` matches Shift+J without
// the upstream on-keys plugin's case-mismatch bug.
//
// `window.kx.fire(combo)` invokes a binding by its combo string. Used by
// the status bar so that clicking a binding fires the same action a
// keypress would.

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

  function dispatch(action) {
    const url = typeof action === "string" ? action : action.url;
    let body;
    if (typeof action === "object" && action.source) {
      const el = document.querySelector(action.source);
      body = el ? el.value : "";
    }
    fetch(url, { method: "POST", body });
  }

  function actionFor(combo) {
    const main = document.querySelector("main");
    const raw = main && main.dataset.keymap;
    if (!raw) return null;
    try {
      const m = JSON.parse(raw);
      return combo in m ? m[combo] : null;
    } catch (_) {
      return null;
    }
  }

  window.kx = {
    fire: function (combo) {
      const action = actionFor(combo);
      if (action != null) dispatch(action);
    },
  };

  document.addEventListener("keydown", function (e) {
    const action = actionFor(comboKey(e));
    if (action == null) return;
    e.preventDefault();
    dispatch(action);
  });
})();
