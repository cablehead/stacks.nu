# stacks.nu MVP server (3-pane datastar UI)
#
# Run:
#   http-nu --datastar --store ./store :3001 ./serve.nu
#
# Persistent topics (see projection.nu for the protocol):
#   stack.add | stack.update | stack.delete
#   clip.add  | clip.move    | clip.delete
# Ephemeral topics:
#   stack.select | clip.select

const script_dir = path self | path dirname

use http-nu/router *
use http-nu/html *
use http-nu/datastar *

use ./projection.nu

# Decorate a clip with a one-line preview and (when small) the inlined body.
def hydrate-clip [clip: record]: nothing -> record {
  let body = if $clip.hash == null { "" } else {
    try { .cas $clip.hash } catch { "" }
  }
  let preview = $body | str replace -ar "\\s+" " " | str trim | str substring 0..120
  $clip | insert preview $preview | insert body $body
}

# Apple-symbol display for special keys; letters stay as-is. Used by the
# status bar; keys.js doesn't see this -- it operates on the `combo` string.
const KEY_GLYPH = {
  "Cmd": "\u{2318}"      # ⌘
  "Ctrl": "\u{2303}"     # ⌃
  "Alt": "\u{2325}"      # ⌥
  "Shift": "\u{21E7}"    # ⇧
  "Enter": "\u{21B5}"    # ↵
  "Esc": "ESC"           # the text "ESC", matching ~/stacks's convention
  "Del": "DEL"           # covers both Delete and Backspace
}

def glyphs [keys: list<string>]: nothing -> list<string> {
  $keys | each {|k| $KEY_GLYPH | get -i $k | default $k }
}

# JS snippets the client evaluates. URL string interpolation happens here so
# the registry value is exactly the JS the browser runs -- no client-side
# template language. POST with no body, or with an arbitrary body expression.
def js-post [url: string]: nothing -> string {
  "fetch(" + ($url | to json -r) + ", {method:'POST'})"
}
def js-post-body [url: string, body_expr: string]: nothing -> string {
  "fetch(" + ($url | to json -r) + ", {method:'POST', body: " + $body_expr + "})"
}
def js-delete [url: string]: nothing -> string {
  "fetch(" + ($url | to json -r) + ", {method:'DELETE'})"
}
def js-confirm-delete [url: string, prompt: string]: nothing -> string {
  "if (confirm(" + ($prompt | to json -r) + ")) fetch(" + ($url | to json -r) + ", {method:'DELETE'})"
}

# Action registry. Action id -> JS string. Triggers (keymap, status-bar
# buttons) reference actions by id; both invoke window.actions.invoke(id),
# which evaluates the JS. This decouples WHAT (action) from HOW IT'S TRIGGERED
# (key, click).
def actions-for [mode: string, ctx: record]: nothing -> record {
  match $mode {
    "compose" => {
      "compose.save":   (js-post-body $"/compose/submit/($ctx.composeStackId)" "document.querySelector('#compose-text').value")
      "compose.cancel": (js-post "/compose/cancel")
    }
    "edit" => {
      "edit.save":   (js-post-body $"/editor/submit/($ctx.editClipId)" "document.querySelector('#compose-text').value")
      "edit.cancel": (js-post "/editor/cancel")
    }
    "rename" => {
      "rename.save":   (js-post-body $"/stacks/($ctx.renameStackId)/rename/submit" "document.querySelector('#rename-text').value")
      "rename.cancel": (js-post "/rename/cancel")
    }
    "actions" => (actions-main $ctx | upsert "actions.cancel" (js-post "/actions/cancel"))
    _ => (actions-main $ctx)
  }
}

# Main-mode action registry. Reused unchanged by "actions" mode (the panel is
# overlaid on main; clicking a row should be able to invoke any main action).
def actions-main [ctx: record]: nothing -> record {
  let core = {
    "clip.next":  (js-post "/select/clip/down")
    "clip.prev":  (js-post "/select/clip/up")
    "clip.top":   (js-post "/select/clip/top")
    "stack.next": (js-post "/select/stack/down")
    "stack.prev": (js-post "/select/stack/up")
    "stack.top":  (js-post "/select/stack/top")
    # Client computes the name at fire-time so the timestamp is in the
    # viewer's local tz, then never changes. ISO-ish 'sv-SE' formats as
    # YYYY-MM-DD HH:MM:SS; we trim to minutes.
    "stack.new":  (js-post-body "/stacks/new" "new Date().toLocaleString('sv-SE').slice(0,16)")
    "actions.open": (js-post "/actions/open")
  }
  let with_n = if $ctx.selectedStackId != null {
    $core | upsert "clip.new" (js-post $"/compose/open/($ctx.selectedStackId)")
  } else { $core }
  let with_e = if $ctx.selectedClipId != null {
    $with_n
    | upsert "clip.edit"   (js-post $"/editor/open/($ctx.selectedClipId)")
    | upsert "clip.delete" (js-delete $"/clips/($ctx.selectedClipId)")
  } else { $with_n }
  if $ctx.selectedStack != null {
    let next_sort = if $ctx.selectedStack.sort == "auto" { "manual" } else { "auto" }
    let stack_label = $ctx.selectedStack.name? | default "this stack"
    $with_e
    | upsert "stack.sort.toggle" (js-post $"/stacks/($ctx.selectedStack.id)/sort/($next_sort)")
    | upsert "stack.rename" (js-post $"/stacks/($ctx.selectedStack.id)/rename/open")
    | upsert "stack.delete" (js-confirm-delete $"/stacks/($ctx.selectedStack.id)" $"Delete stack \"($stack_label)\"?")
  } else { $with_e }
}

# Keyboard triggers: combo -> action id. Same combo normalization as keys.js
# (`cmd+ctrl+alt+shift+key`, letters lowercased).
def keymap-for [mode: string, ctx: record]: nothing -> record {
  match $mode {
    "compose" => {"cmd+enter": "compose.save", "escape": "compose.cancel"}
    "edit" => {"cmd+enter": "edit.save", "escape": "edit.cancel"}
    "rename" => {"enter": "rename.save", "cmd+enter": "rename.save", "escape": "rename.cancel"}
    "actions" => {"escape": "actions.cancel", "cmd+k": "actions.cancel"}
    _ => (keymap-main $ctx)
  }
}

def keymap-main [ctx: record]: nothing -> record {
  let base = {
    "j": "clip.next", "k": "clip.prev"
    "ctrl+n": "clip.next", "ctrl+p": "clip.prev"
    "0": "clip.top"
    "shift+j": "stack.next", "shift+k": "stack.prev"
    "shift+0": "stack.top", "shift+)": "stack.top"
    "shift+n": "stack.new"
    "cmd+k": "actions.open"
  }
  let with_stack = if $ctx.selectedStackId != null {
    $base
    | upsert "n" "clip.new"
    | upsert "r" "stack.rename"
    | upsert "shift+delete"    "stack.delete"
    | upsert "shift+backspace" "stack.delete"
  } else { $base }
  if $ctx.selectedClipId != null {
    $with_stack
    | upsert "e" "clip.edit"
    | upsert "delete"    "clip.delete"
    | upsert "backspace" "clip.delete"
  } else { $with_stack }
}

# Status bar (right side): visible bindings, each referencing an action id.
def bindings-for [mode: string, ctx: record]: nothing -> list {
  match $mode {
    "compose" => [
      {action: "compose.save"   label: "save"   keys: (glyphs [Cmd Enter])}
      {action: "compose.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "edit" => [
      {action: "edit.save"   label: "save"   keys: (glyphs [Cmd Enter])}
      {action: "edit.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "rename" => [
      {action: "rename.save"   label: "save"   keys: (glyphs [Enter])}
      {action: "rename.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "actions" => [
      {action: "actions.cancel" label: "close" keys: (glyphs [Esc])}
    ]
    _ => [
      {action: "clip.next"    label: "next clip"  keys: (glyphs [J])}
      {action: "clip.prev"    label: "prev clip"  keys: (glyphs [K])}
      {action: "stack.next"   label: "next stack" keys: (glyphs [Shift J])}
      {action: "stack.prev"   label: "prev stack" keys: (glyphs [Shift K])}
      {action: "actions.open" label: "actions"    keys: (glyphs [Cmd K])}
    ]
  }
}

# Action panel (Cmd+K): flat list, ordered clip-then-stack. Each row's
# `require` field gates visibility against the current selection (~/stacks's
# canApply pattern). Returns the rows that should appear given ctx.
def panel-actions-for [ctx: record]: nothing -> list {
  let items = [
    {action: "clip.new"          label: "New clip"     keys: (glyphs [N])         target: "clip"  require: "stack"}
    {action: "clip.edit"         label: "Edit clip"    keys: (glyphs [E])         target: "clip"  require: "clip"}
    {action: "clip.delete"       label: "Delete clip"  keys: (glyphs [Del])       target: "clip"  require: "clip"}
    {action: "stack.new"         label: "New stack"    keys: (glyphs [Shift N])   target: "stack" require: "always"}
    {action: "stack.rename"      label: "Rename stack" keys: (glyphs [R])         target: "stack" require: "stack"}
    {action: "stack.sort.toggle" label: "Toggle sort"  keys: []                   target: "stack" require: "stack"}
    {action: "stack.delete"      label: "Delete stack" keys: (glyphs [Shift Del]) target: "stack" require: "stack"}
  ]
  let visible = $items | where {|x|
    match $x.require {
      "always" => true
      "stack"  => ($ctx.selectedStackId != null)
      "clip"   => ($ctx.selectedClipId != null)
      _ => false
    }
  }
  # Mark each row that starts a new target group so the template can insert
  # a divider before it. The first row never gets the flag.
  $visible | enumerate | each {|e|
    let prev = if $e.index == 0 { null } else { $visible | get ($e.index - 1) | get target }
    $e.item | upsert groupStart (($e.index > 0) and ($e.item.target != $prev))
  }
}

# Status bar (left side): stack-related affordances, each referencing an
# action id. Empty list when there's no useful target.
def stack-actions-for [mode: string, ctx: record]: nothing -> list {
  if $mode != "main" { return [] }
  let stack = $ctx.selectedStack
  if $stack == null { return [] }
  let icon = if $stack.sort == "auto" {
    "lucide:arrow-down-narrow-wide"
  } else {
    "lucide:list-ordered"
  }
  [{action: "stack.sort.toggle" label: $"sort: ($stack.sort)" icon: $icon}]
}

# What goes on the LEFT of the status bar -- the stack name in main mode,
# the modal title elsewhere.
def mode-name-for [mode: string, ctx: record]: nothing -> string {
  match $mode {
    "compose" => $"New clip in ($ctx.composeStackName)"
    "edit" => $"Edit clip in ($ctx.editStackName)"
    "rename" => "Rename stack"
    "actions" => "Actions"
    _ => {
      if $ctx.selectedStack == null { "Stacks" } else { ($ctx.selectedStack.name? | default "Untitled") }
    }
  }
}

# Locate a clip across all stacks; returns {clip, stackName} or null.
def find-clip [state: record, clip_id: any]: nothing -> any {
  if $clip_id == null { return null }
  for s in $state.stacks {
    let hit = $s.clips | where id == $clip_id | get -i 0
    if $hit != null { return {clip: $hit stackName: $s.name} }
  }
  null
}

# Take the projection state and turn it into the template's view model.
def view-model [state: record]: nothing -> record {
  let stack = $state.stacks | where id == $state.selectedStackId | get -i 0
  let raw_clips = if $stack == null { [] } else { projection sorted-clips $stack }
  let clips = $raw_clips | each {|c| hydrate-clip $c }
  let selected = $clips | where id == $state.selectedClipId | get -i 0
  let compose_stack = $state.stacks | where id == $state.composeStackId | get -i 0
  let edit_target = find-clip $state $state.editClipId
  let edit_clip = if $edit_target == null { null } else { hydrate-clip $edit_target.clip }
  let compose_name = if $compose_stack == null { "" } else { $compose_stack.name }
  let edit_name = if $edit_target == null { "" } else { $edit_target.stackName }
  let rename_stack = $state.stacks | where id == $state.renameStackId | get -i 0
  let rename_initial = if $rename_stack == null { "" } else { $rename_stack.name? | default "" }
  let ctx = {
    composeStackId: $state.composeStackId
    composeStackName: $compose_name
    editClipId: $state.editClipId
    editStackName: $edit_name
    renameStackId: $state.renameStackId
    selectedStackId: $state.selectedStackId
    selectedClipId: $state.selectedClipId
    selectedStack: $stack
  }
  let actions = actions-for $state.mode $ctx
  let keymap = keymap-for $state.mode $ctx
  let bindings = bindings-for $state.mode $ctx
  let stack_actions = stack-actions-for $state.mode $ctx
  let panel_actions = panel-actions-for $ctx
  # Stacks ordered by recent activity (any event touching the stack or its clips).
  let stacks_sorted = $state.stacks | sort-by lastTouched | reverse
  {
    stacks: $stacks_sorted
    selectedStackId: $state.selectedStackId
    selectedClipId: $state.selectedClipId
    clips: $clips
    selectedClip: $selected
    mode: $state.mode
    modeName: (mode-name-for $state.mode $ctx)
    composeStackId: $state.composeStackId
    composeStackName: $compose_name
    editClipId: $state.editClipId
    editClip: $edit_clip
    editStackName: $edit_name
    renameStackId: $state.renameStackId
    renameInitial: $rename_initial
    bindings: $bindings
    stackActions: $stack_actions
    panelActions: $panel_actions
    actions: ($actions | to json -r)
    keymap: ($keymap | to json -r)
  }
}

def render-event [state: record]: nothing -> record {
  let html = view-model $state | .mj ($script_dir | path join "templates/three-pane.html.j2")
  let elements = $html | lines | each {|l| $"elements ($l)" } | str join "\n"
  {event: "datastar-patch-elements" data: $"selector main\n($elements)"}
}

# Synthetic state for the /design page. Same shape projection produces, but
# hand-rolled so we can vary the mode without driving a live store.
def design-state [variant: string]: nothing -> record {
  let stacks = [
    {id: "s1" name: "Inbox"    sort: "auto"   lastTouched: "f3"
      clips: [
        {id: "c1" hash: "fake-h1" mime_type: "text/plain" position: null lastTouched: "c1" versions: ["c1"]}
        {id: "c2" hash: "fake-h2" mime_type: "text/plain" position: null lastTouched: "c2" versions: ["c2"]}
      ]}
    {id: "s2" name: "Snippets" sort: "manual" lastTouched: "c4"
      clips: [
        {id: "c3" hash: "fake-h3" mime_type: "text/plain" position: "a" lastTouched: "c3" versions: ["c3"]}
        {id: "c4" hash: "fake-h4" mime_type: "text/plain" position: "b" lastTouched: "c4" versions: ["c4"]}
      ]}
    {id: "s3" name: "Untitled" sort: "auto"   lastTouched: "s3" clips: []}
  ]
  let base = projection empty
    | update stacks $stacks
    | update selectedStackId "s1"
    | update selectedClipId "c1"
    | update selectionExplicit true
  match $variant {
    "main"             => $base
    "main-empty-stack" => ($base | update selectedStackId "s3" | update selectedClipId null)
    "compose"          => ($base | update mode "compose" | update composeStackId "s1")
    "edit"             => ($base | update mode "edit"    | update editClipId "c1")
    "rename"           => ($base | update mode "rename"  | update renameStackId "s1")
    "actions"          => ($base | update mode "actions")
    _ => $base
  }
}

# Render one mode into a self-contained HTML doc suitable for iframe srcdoc.
# No scripts loaded -- the page is inert; click handlers reference an undefined
# window.actions and silently no-op.
def design-tile-html [variant: string]: nothing -> string {
  let state = design-state $variant
  let main_html = view-model $state | .mj ($script_dir | path join "templates/three-pane.html.j2")
  [
    "<!DOCTYPE html><html><head><meta charset='utf-8'>"
    "<link rel='stylesheet' href='/stellar.css'>"
    "<link rel='stylesheet' href='/base.css'>"
    "<script src='https://cdn.jsdelivr.net/npm/iconify-icon@2/dist/iconify-icon.min.js'></script>"
    "</head><body>"
    $main_html
    "</body></html>"
  ] | str join
}

def design-page []: nothing -> any {
  let variants = ["main" "main-empty-stack" "compose" "edit" "rename" "actions"]
  (
    HTML
    (
      HEAD
      (META {charset: "utf-8"})
      (TITLE "stacks.nu | design")
      (LINK {rel: "stylesheet" href: "/stellar.css"})
      (LINK {rel: "stylesheet" href: "/base.css"})
      (SCRIPT-ICONIFY)
    )
    (
      BODY {style: "padding: 1.5rem; background: var(--primary-6); color: var(--primary-6-on); font-family: var(--font-sans); margin: 0; height: 100vh; overflow: auto;"}
      (H1 {style: "font-size: var(--font-size-2); margin: 0 0 .25rem;"} "stacks.nu | design")
      (P {style: "color: var(--primary-7-dim); font-size: var(--font-size--1); margin: 0 0 1.5rem;"}
        "Inert layout previews of every mode. Each tile is an iframe rendering the live template at a fixed state.")
      (
        DIV {style: "display: grid; grid-template-columns: repeat(auto-fill, minmax(40rem, 1fr)); gap: 1.5rem;"}
        ($variants | each {|v|
          (FIGURE {style: "margin: 0; background: var(--primary-7); border: 1px solid var(--primary-7-dim); border-radius: var(--border-radius-2); overflow: hidden;"}
            (IFRAME {srcdoc: (design-tile-html $v) title: $v style: "width: 100%; height: 26rem; border: 0; display: block;"})
            (FIGCAPTION {style: "padding: .5rem .75rem; font-family: var(--font-mono); font-size: var(--font-size--1); color: var(--primary-7-on); border-top: 1px solid var(--primary-7-dim);"} $v)
          )
        })
      )
    )
  )
}

def shots-page []: nothing -> any {
  let dir = $script_dir | path join "static/shots"
  let files = if ($dir | path exists) {
    ls $dir | where ($it.name | str ends-with ".png") | get name | each {|p| $p | path basename } | sort
  } else { [] }
  (
    HTML
    (
      HEAD
      (META {charset: "utf-8"})
      (TITLE "stacks.nu | screenshots")
      (LINK {rel: "stylesheet" href: "/stellar.css"})
      (LINK {rel: "stylesheet" href: "/base.css"})
    )
    (
      BODY {style: "padding: 1.5rem; background: var(--primary-6); color: var(--primary-6-on); font-family: var(--font-sans);"}
      (H1 {style: "font-size: var(--font-size-2); margin: 0 0 1rem;"} "stacks.nu screenshots")
      (P {style: "color: var(--primary-7-dim); font-size: var(--font-size--1); margin: 0 0 1.5rem;"}
        $"($files | length) pose"
        (if ($files | length) == 1 { "" } else { "s" })
        " in "
        (CODE "www/static/shots/")
      )
      (if ($files | is-empty) {
        (P {style: "color: var(--primary-7-dim);"} "No shots yet. Run "
          (CODE "scripts/shoot.py") " to bake some.")
      } else {
        (
          DIV {style: "display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 1rem;"}
          ($files | each {|f|
            let slug = $f | str replace ".png" "" | str replace -a "-" " "
            (FIGURE {style: "margin: 0; background: var(--primary-7); border: 1px solid var(--primary-7-dim); border-radius: var(--border-radius-2); overflow: hidden;"}
              (IMG {src: $"/shots/($f)" alt: $slug style: "width: 100%; display: block;"})
              (FIGCAPTION {style: "padding: .5rem .75rem; font-family: var(--font-mono); font-size: var(--font-size--1); color: var(--primary-7-on); border-top: 1px solid var(--primary-7-dim);"} $slug)
            )
          })
        )
      })
    )
  )
}

def index-page []: nothing -> any {
  (
    HTML
    (
      HEAD
      # Pre-paint theme apply -- runs synchronously before the stylesheet so
      # there's no light->dark flash. localStorage wins; otherwise system pref.
      (
        SCRIPT {__html: "
(function() {
  var saved = localStorage.getItem('theme');
  var dark = saved ? saved === 'dark' : window.matchMedia('(prefers-color-scheme:dark)').matches;
  if (dark) document.documentElement.classList.add('dark');
})();
"}
      )
      (META {charset: "utf-8"})
      (META {name: "viewport" content: "width=device-width,initial-scale=1"})
      (TITLE "stacks.nu")
      (LINK {rel: "stylesheet" href: "/stellar.css"})
      (LINK {rel: "stylesheet" href: "/base.css"})
      (SCRIPT {type: "module" src: $DATASTAR_JS_PATH})
      (SCRIPT-ICONIFY)
      (SCRIPT {src: "/keys.js"})
      (SCRIPT {src: "/action-panel.js"})
      # Theme toggle handler. Lives at window.toggleTheme so the status-bar
      # button can call it inline; persists choice and updates the icon.
      (
        SCRIPT {__html: "
window.toggleTheme = function() {
  var isDark = document.documentElement.classList.toggle('dark');
  localStorage.setItem('theme', isDark ? 'dark' : 'light');
  var icon = document.querySelector('#theme-toggle iconify-icon');
  if (icon) icon.setAttribute('icon', isDark ? 'lucide:sun' : 'lucide:moon');
};
"}
      )
    )
    (
      BODY {data-init: "@get('/updates')"}
      (MAIN "loading...")
    )
  )
}

{|req|
  dispatch $req [
    (route {method: "GET" path: "/"} {|req ctx| index-page })
    (route {method: "GET" path: "/shots"} {|req ctx| shots-page })
    (route {method: "GET" path: "/design"} {|req ctx| design-page })

    (route {method: "GET" path: "/updates"} {|req ctx|
      .cat -f
      | projection project-stream
      | each {|s| render-event $s }
      | to sse
    })

    # ---- selection (ephemeral) ----
    (route {method: "POST" path: "/select/stack/down"} {|req ctx|
      .append stack.select --meta {action: "down"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/select/stack/up"} {|req ctx|
      .append stack.select --meta {action: "up"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/select/stack/top"} {|req ctx|
      .append stack.select --meta {action: "top"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/select/stack/:id"} {|req ctx|
      .append stack.select --meta {id: $ctx.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/select/clip/down"} {|req ctx|
      .append clip.select --meta {action: "down"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/select/clip/up"} {|req ctx|
      .append clip.select --meta {action: "up"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/select/clip/top"} {|req ctx|
      .append clip.select --meta {action: "top"} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/select/clip/:id"} {|req ctx|
      .append clip.select --meta {id: $ctx.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- compose (ephemeral modal mode) ----
    (route {method: "POST" path-matches: "/compose/open/:id"} {|req ctx|
      .append compose.open --meta {stack_id: $ctx.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/compose/cancel"} {|req ctx|
      .append compose.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/compose/submit/:id"} {|req ctx|
      let text = $in
      if not ($text | str trim | is-empty) {
        $text | .append clip.add --meta {stack_id: $ctx.id mime_type: "text/plain"} | ignore
      }
      .append compose.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- actions panel (ephemeral modal mode; pure overlay, no submit) ----
    (route {method: "POST" path: "/actions/open"} {|req ctx|
      .append actions.open --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/actions/cancel"} {|req ctx|
      .append actions.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- rename (ephemeral modal mode; submits as stack.update) ----
    (route {method: "POST" path-matches: "/stacks/:id/rename/open"} {|req ctx|
      .append rename.open --meta {stack_id: $ctx.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/rename/cancel"} {|req ctx|
      .append rename.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/stacks/:id/rename/submit"} {|req ctx|
      let name = $in | default "" | str trim
      if not ($name | is-empty) {
        .append stack.update --meta {id: $ctx.id name: $name} | ignore
      }
      .append rename.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- editor (ephemeral modal mode; submits as add-new + delete-old) ----
    (route {method: "POST" path-matches: "/editor/open/:id"} {|req ctx|
      .append editor.open --meta {clip_id: $ctx.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/editor/cancel"} {|req ctx|
      .append editor.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/editor/submit/:id"} {|req ctx|
      let text = $in
      if not ($text | str trim | is-empty) {
        # clip.update keeps the clip's identity stable -- selection, position,
        # mime type all stay attached to the same id. Prior content lives on
        # in the event log under the original clip.add and any earlier
        # clip.update frames.
        $text | .append clip.update --meta {id: $ctx.id} | ignore
      }
      .append editor.close --meta {} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- mutations ----
    (route {method: "POST" path: "/stacks/new"} {|req ctx|
      # Bare-keymap action: create a stack and select it. The client supplies
      # the name (a timestamp formatted in the viewer's local tz on shift-N);
      # an empty body leaves the name null. Rename comes via PATCH /stacks/:id.
      let name = $in | default "" | str trim
      let meta = if ($name | is-empty) { {sort: "auto"} } else { {name: $name sort: "auto"} }
      let frame = .append stack.add --meta $meta
      .append stack.select --meta {id: $frame.id} --ttl ephemeral | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path: "/stacks"} {|req ctx|
      let body = $in | from json
      let meta = {
        name: ($body.name? | default "Untitled")
        sort: ($body.sort? | default "auto")
      }
      .append stack.add --meta $meta
    })
    (route {method: "PATCH" path-matches: "/stacks/:id"} {|req ctx|
      let body = $in | from json
      .append stack.update --meta ($body | merge {id: $ctx.id})
    })
    (route {method: "POST" path-matches: "/stacks/:id/sort/:mode"} {|req ctx|
      .append stack.update --meta {id: $ctx.id sort: $ctx.mode} | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "DELETE" path-matches: "/stacks/:id"} {|req ctx|
      .append stack.delete --meta {id: $ctx.id}
    })
    (route {method: "POST" path-matches: "/stacks/:id/clips"} {|req ctx|
      let body = $in
      let mime = $req.query?.mime_type? | default "text/plain"
      let pos = $req.query?.position?
      let base = {stack_id: $ctx.id mime_type: $mime}
      let meta = if $pos != null { $base | merge {position: $pos} } else { $base }
      $body | .append clip.add --meta $meta
    })
    (route {method: "PATCH" path-matches: "/clips/:id"} {|req ctx|
      let body = $in | from json
      .append clip.move --meta ($body | merge {id: $ctx.id})
    })
    (route {method: "DELETE" path-matches: "/clips/:id"} {|req ctx|
      .append clip.delete --meta {id: $ctx.id}
    })

    # ---- content + assets ----
    (route {method: "GET" path-matches: "/clips/:id/content"} {|req ctx|
      let frame = .get $ctx.id
      if $frame == null or $frame.hash? == null {
        "Not Found" | metadata set { merge {'http.response': {status: 404}} }
      } else {
        let mime = $frame.meta?.mime_type? | default "application/octet-stream"
        .cas $frame.hash | metadata set { merge {'http.response': {headers: {"Content-Type": $mime}}} }
      }
    })
    (route {method: "GET"} {|req ctx|
      .static ($script_dir | path join "static") $req.path
    })

    (route true {|req ctx|
      "Not Found" | metadata set { merge {'http.response': {status: 404}} }
    })
  ]
}
