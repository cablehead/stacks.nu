# stacks.nu MVP server (3-pane datastar UI)
#
# Run:
#   http-nu --datastar --store ./store :3001 ./serve.nu
#
# Persistent topics (see projection.nu for the protocol):
#   stack.add | stack.update | stack.delete
#   clip.add  | clip.patch   | clip.delete
# Ephemeral topics:
#   stack.select | clip.select

const script_dir = path self | path dirname

use http-nu/router *
use http-nu/html *
use http-nu/datastar *

use ./projection.nu

# Decorate a clip with a one-line preview and (when small) the inlined body.
# Fetch a CAS body and a one-line text preview, gated on mime type. Binary
# blobs (image/*, application/octet-stream, ...) would crash the str-* pipe;
# they get an empty body and a "(<mime>)" placeholder preview. Returns
# {body, preview, is_text} -- callers wrap with their own metadata.
def cas-preview [hash: any mime: any]: nothing -> record {
  let m = $mime | default "text/plain"
  let is_text = ($m | str starts-with "text/") or $m == "application/json"
  let body = if $hash == null or (not $is_text) { "" } else {
    try { .cas $hash } catch { "" }
  }
  let preview = if $is_text {
    $body | str replace -ar "\\s+" " " | str trim | str substring 0..120
  } else {
    $"\(($m)\)"
  }
  {body: $body preview: $preview is_text: $is_text}
}

def hydrate-clip [clip: record]: nothing -> record {
  let mime = $clip.mime_type? | default "text/plain"
  let p = cas-preview $clip.hash? $mime
  # Inline `body` on the input record (e.g. /design's synthetic clips,
  # where hashes don't resolve in CAS) wins over the CAS read. Recompute
  # preview from it so the inline body shows up in the clip list too.
  let inline = $clip.body? | default ""
  let body = if ($inline | is-empty) { $p.body } else { $inline }
  let preview = if ($inline | is-empty) { $p.preview } else {
    $inline | str replace -ar "\\s+" " " | str trim | str substring 0..120
  }
  let body_html = if $mime == "text/markdown" {
    try { $body | .md | get __html } catch { "" }
  } else { "" }
  $clip | upsert preview $preview | upsert body $body | upsert bodyHtml $body_html
}

# Apple-symbol display for special keys; letters stay as-is. Used by the
# status bar; keys.js doesn't see this -- it operates on the `combo` string.
const KEY_GLYPH = {
  "Cmd": "\u{2318}" # ⌘
  "Ctrl": "\u{2303}" # ⌃
  "Alt": "\u{2325}" # ⌥
  "Shift": "\u{21E7}" # ⇧
  "Enter": "\u{21B5}" # ↵
  "Esc": "ESC" # the text "ESC", matching ~/stacks's convention
  "Del": "DEL" # covers both Delete and Backspace
}

def glyphs [keys: list<string>]: nothing -> list<string> {
  $keys | each {|k| $KEY_GLYPH | get -i $k | default $k }
}

# Platform modifier resolved server-side. keys.js emits `cmd+...` from
# metaKey (Mac Cmd) and `ctrl+...` from ctrlKey, so whichever string we
# send is what will match the user's actual keystroke.
def mod-key [is_mac: bool]: nothing -> string {
  if $is_mac { "cmd" } else { "ctrl" }
}
def mod-glyph [is_mac: bool]: nothing -> string {
  if $is_mac { "Cmd" } else { "Ctrl" }
}

# Detect the viewer's platform from request headers. sec-ch-ua-platform is
# the modern signal (Chromium); fall back to user-agent substring match.
# Defaults to true (Mac) when nothing's available, since the original
# audience was Mac users.
def is-mac [req: record]: nothing -> bool {
  let ch = $req.headers? | default {} | get -i "sec-ch-ua-platform" | default ""
  if ($ch | str length) > 0 {
    return (($ch | str downcase | str trim --char '"') == "macos")
  }
  let ua = $req.headers? | default {} | get -i "user-agent" | default ""
  ($ua | str contains "Mac OS X") or ($ua | str contains "Macintosh")
}

# JS snippets the client evaluates. URL string interpolation happens here so
# the registry value is exactly the JS the browser runs -- no client-side
# template language.
#
# js-fetch covers POST / DELETE / PATCH callsites:
#   --method:  HTTP method (default POST)
#   --body:    raw JS expression evaluated as the request body
#   --json:    value JSON-serialized as the body; also sets content-type
#   --confirm: prompt; gates the fetch in `if (confirm("..."))`
#   --then:    raw JS chained via `.finally(() => <expr>)`
def js-fetch [
  url: string
  --method: string = "POST"
  --body: string
  --json: any
  --confirm: string
  --then: string
]: nothing -> string {
  let url_lit = $url | to json -r
  let body_part = if $json != null {
    let payload = $json | to json -r
    $", headers:{'content-type':'application/json'}, body: ($payload | to json -r)"
  } else if $body != null {
    $", body: ($body)"
  } else { "" }
  let call = $"fetch\(($url_lit), {method:'($method)'($body_part)}\)"
  let chained = if $then != null {
    $"($call).finally\(\(\) => ($then)\)"
  } else { $call }
  if $confirm != null {
    $"if \(confirm\(($confirm | to json -r)\)\) ($chained)"
  } else { $chained }
}

# Impulse: fire-and-forget signal to the projection. The server validates
# topic against IMPULSE_TOPICS; meta is the frame's meta. For ephemeral nav
# events only -- not persistent mutations (those keep dedicated REST routes).
def js-impulse [topic: string meta: record]: nothing -> string {
  $"window.actions.impulse\(($topic | to json -r), ($meta | to json -r)\)"
}

# Allowlist of topics the /_impulse endpoint will accept. Anything else --
# in particular any persistent topic -- is rejected.
const IMPULSE_TOPICS = [
  "stack.select"
  "clip.select"
  "compose.open"
  "compose.close"
  "editor.open"
  "editor.close"
  "rename.open"
  "rename.close"
  "actions.open"
  "actions.close"
  "set-mime.open"
  "set-mime.close"
  "trash.open"
  "trash.close"
  "deleted.select"
  "pipe.open"
  "pipe.close"
  "pipe.history.open"
  "pipe.history.close"
  "pipe.history.cursor"
  "pipe.history.select"
]

# Action registry. Action id -> JS string. Triggers (keymap, status-bar
# buttons) reference actions by id; both invoke window.actions.invoke(id),
# which evaluates the JS. This decouples WHAT (action) from HOW IT'S TRIGGERED
# (key, click).
def actions-for [mode: string ctx: record]: nothing -> record {
  match $mode {
    "compose" => {
      "compose.save": (js-fetch $"/compose/submit/($ctx.composeStackId)" --body "document.querySelector('#compose-text').value")
      "compose.cancel": (js-impulse "compose.close" {})
    }
    "edit" => {
      "edit.save": (js-fetch $"/editor/submit/($ctx.editClipId)" --body "document.querySelector('#compose-text').value")
      "edit.cancel": (js-impulse "editor.close" {})
    }
    "rename" => {
      "rename.save": (js-fetch $"/stacks/($ctx.renameStackId)/rename/submit" --body "document.querySelector('#rename-text').value")
      "rename.cancel": (js-impulse "rename.close" {})
    }
    "actions" => (actions-main $ctx | upsert "actions.cancel" (js-impulse "actions.close" {}))
    "set-mime" => {
      "set-mime.plain": (js-fetch $"/clips/($ctx.setMimeClipId)" --method PATCH --json {mime_type: "text/plain"} --then (js-impulse "set-mime.close" {}))
      "set-mime.markdown": (js-fetch $"/clips/($ctx.setMimeClipId)" --method PATCH --json {mime_type: "text/markdown"} --then (js-impulse "set-mime.close" {}))
      "set-mime.cancel": (js-impulse "set-mime.close" {})
    }
    "trash" => {
      "trash.cancel": (js-impulse "trash.close" {})
      "deleted.next": (js-impulse "deleted.select" {action: "down"})
      "deleted.prev": (js-impulse "deleted.select" {action: "up"})
      "restore.do": (if $ctx.selectedDeletedFrameId == null { "" } else {
        js-fetch $"/trash/restore/($ctx.selectedDeletedFrameId)"
      })
    }
    "pipe" => {
      # Mod+Enter: read the currently-highlighted history row at fire time
      # (data-history-source on .is-current). Falls back to the input value
      # when no row is highlighted (popup closed or empty filter). Reading
      # from the DOM avoids the round-trip race where the cursor has moved
      # but data-actions hasn't been re-patched yet.
      "pipe.run": (js-fetch $"/pipe/run/($ctx.pipeClipId)"
      --body "(document.querySelector('.pipe-history-row.is-current')?.dataset.historySource ?? document.querySelector('#pipe-text').value)"
      --then "(() => { const r = document.querySelector('.pipe-history-row.is-current'); return r && window.actions.impulse('pipe.history.select', {source: r.dataset.historySource}); })()")
      "pipe.cancel": (js-impulse "pipe.close" {})
      "pipe.history.open": (js-impulse "pipe.history.open" {})
      "pipe.history.close": (js-impulse "pipe.history.close" {})
      "pipe.history.up": (js-impulse "pipe.history.cursor" {action: "up"})
      "pipe.history.down": (js-impulse "pipe.history.cursor" {action: "down"})
      "pipe.history.select": (js-impulse "pipe.history.select" {})
    }
    _ => (actions-main $ctx)
  }
}

# Main-mode action registry. Reused unchanged by "actions" mode (the panel is
# overlaid on main; clicking a row should be able to invoke any main action).
def actions-main [ctx: record]: nothing -> record {
  let core = {
    "clip.next": (js-impulse "clip.select" {action: "down"})
    "clip.prev": (js-impulse "clip.select" {action: "up"})
    "clip.top": (js-impulse "clip.select" {action: "top"})
    "stack.next": (js-impulse "stack.select" {action: "down"})
    "stack.prev": (js-impulse "stack.select" {action: "up"})
    "stack.top": (js-impulse "stack.select" {action: "top"})
    # Client computes the name at fire-time so the timestamp is in the
    # viewer's local tz, then never changes. ISO-ish 'sv-SE' formats as
    # YYYY-MM-DD HH:MM:SS; we trim to minutes.
    "stack.new": (js-fetch "/stacks/new" --body "new Date().toLocaleString('sv-SE').slice(0,16)")
    "actions.open": (js-impulse "actions.open" {})
    "trash.open": (js-impulse "trash.open" {})
  }
  let with_n = if $ctx.selectedStackId != null {
    $core | upsert "clip.new" (js-impulse "compose.open" {stack_id: $ctx.selectedStackId})
  } else { $core }
  let with_e = if $ctx.selectedClipId != null {
    $with_n
    | upsert "clip.edit" (js-impulse "editor.open" {clip_id: $ctx.selectedClipId})
    | upsert "clip.delete" (js-fetch $"/clips/($ctx.selectedClipId)" --method DELETE)
    | upsert "clip.set-mime" (js-impulse "set-mime.open" {clip_id: $ctx.selectedClipId})
    | upsert "clip.pipe" (js-impulse "pipe.open" {clip_id: $ctx.selectedClipId})
  } else { $with_n }
  if $ctx.selectedStack != null {
    let next_sort = if $ctx.selectedStack.sort == "auto" { "manual" } else { "auto" }
    let stack_label = $ctx.selectedStack.name? | default "this stack"
    $with_e
    | upsert "stack.sort.toggle" (js-fetch $"/stacks/($ctx.selectedStack.id)/sort/($next_sort)")
    | upsert "stack.rename" (js-impulse "rename.open" {stack_id: $ctx.selectedStack.id})
    | upsert "stack.delete" (js-fetch $"/stacks/($ctx.selectedStack.id)" --method DELETE --confirm $"Delete stack \"($stack_label)\"?")
  } else { $with_e }
}

# Keyboard triggers: combo -> action id. Same combo normalization as keys.js
# (`cmd+ctrl+alt+shift+key`, letters lowercased).
def keymap-for [mode: string ctx: record]: nothing -> record {
  let mod = mod-key $ctx.isMac
  match $mode {
    "compose" => ({"escape": "compose.cancel"} | upsert $"($mod)+enter" "compose.save")
    "edit" => ({"escape": "edit.cancel"} | upsert $"($mod)+enter" "edit.save")
    "rename" => ({"enter": "rename.save" "escape": "rename.cancel"} | upsert $"($mod)+enter" "rename.save")
    "actions" => ({"escape": "actions.cancel"} | upsert $"($mod)+k" "actions.cancel")
    "set-mime" => {"escape": "set-mime.cancel"}
    "trash" => {
      "escape": "trash.cancel"
      "j": "deleted.next"
      "k": "deleted.prev"
      "ctrl+n": "deleted.next"
      "ctrl+p": "deleted.prev"
      "enter": "restore.do"
      "u": "restore.do"
    }
    "pipe" => (if $ctx.pipeHistoryOpen {
      # Popup open: arrows / Ctrl+P / Ctrl+N navigate rows, Enter selects,
      # Esc closes popup. Mod+Enter still runs the input regardless.
      # Ctrl+P/N work even with input focused -- the document-level keydown
      # handler runs before the input consumes the event.
      {
        "escape": "pipe.history.close"
        "arrowup": "pipe.history.up"
        "arrowdown": "pipe.history.down"
        "ctrl+p": "pipe.history.up"
        "ctrl+n": "pipe.history.down"
        "enter": "pipe.history.select"
      } | upsert $"($mod)+enter" "pipe.run"
    } else {
      {
        "escape": "pipe.cancel"
        "arrowup": "pipe.history.open"
        "ctrl+p": "pipe.history.open"
      } | upsert $"($mod)+enter" "pipe.run"
    })
    _ => (keymap-main $ctx)
  }
}

def keymap-main [ctx: record]: nothing -> record {
  let mod = mod-key $ctx.isMac
  let with_trash = if $ctx.hasDeleted { {"shift+t": "trash.open"} } else { {} }
  let base = ($with_trash | upsert $"($mod)+k" "actions.open") | merge {
      "j": "clip.next"
      "k": "clip.prev"
      "ctrl+n": "clip.next"
      "ctrl+p": "clip.prev"
      "0": "clip.top"
      "shift+j": "stack.next"
      "shift+k": "stack.prev"
      "shift+0": "stack.top"
      "shift+)": "stack.top"
      "shift+n": "stack.new"
    }
  let with_stack = if $ctx.selectedStackId != null {
    $base
    | upsert "n" "clip.new"
    | upsert "r" "stack.rename"
    | upsert "shift+delete" "stack.delete"
    | upsert "shift+backspace" "stack.delete"
  } else { $base }
  if $ctx.selectedClipId != null {
    $with_stack
    | upsert "e" "clip.edit"
    | upsert "p" "clip.pipe"
    | upsert "delete" "clip.delete"
    | upsert "backspace" "clip.delete"
  } else { $with_stack }
}

# Status bar (right side): visible bindings, each referencing an action id.
def bindings-for [mode: string ctx: record]: nothing -> list {
  let m = mod-glyph $ctx.isMac
  match $mode {
    "compose" => [
      {action: "compose.save" label: "save" keys: (glyphs [$m Enter])}
      {action: "compose.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "edit" => [
      {action: "edit.save" label: "save" keys: (glyphs [$m Enter])}
      {action: "edit.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "rename" => [
      {action: "rename.save" label: "save" keys: (glyphs [Enter])}
      {action: "rename.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "actions" => [
      {action: "actions.cancel" label: "close" keys: (glyphs [Esc])}
    ]
    "set-mime" => [
      {action: "set-mime.cancel" label: "cancel" keys: (glyphs [Esc])}
    ]
    "trash" => [
      {action: "restore.do" label: "restore" keys: (glyphs [Enter])}
      {action: "deleted.next" label: "next" keys: (glyphs [J])}
      {action: "deleted.prev" label: "prev" keys: (glyphs [K])}
      {action: "trash.cancel" label: "close" keys: (glyphs [Esc])}
    ]
    "pipe" => (if $ctx.pipeHistoryOpen {
      [
        {action: "pipe.history.select" label: "select" keys: (glyphs [Enter])}
        {action: "pipe.history.close" label: "close" keys: (glyphs [Esc])}
        {action: "pipe.run" label: "run" keys: (glyphs [$m Enter])}
      ]
    } else {
      [
        {action: "pipe.run" label: "run" keys: (glyphs [$m Enter])}
        {action: "pipe.history.open" label: "history" keys: ["\u{2191}"]}
        {action: "pipe.cancel" label: "cancel" keys: (glyphs [Esc])}
      ]
    })
    _ => [
      {action: "clip.next" label: "next clip" keys: (glyphs [J])}
      {action: "clip.prev" label: "prev clip" keys: (glyphs [K])}
      {action: "stack.next" label: "next stack" keys: (glyphs [Shift J])}
      {action: "stack.prev" label: "prev stack" keys: (glyphs [Shift K])}
      {action: "actions.open" label: "actions" keys: (glyphs [$m K])}
    ]
  }
}

# Action panel (Cmd+K): flat list, ordered clip-then-stack. Each row's
# `require` field gates visibility against the current selection (~/stacks's
# canApply pattern). Returns the rows that should appear given ctx.
def panel-actions-for [mode: string ctx: record]: nothing -> list {
  if $mode == "set-mime" {
    return [
      {action: "set-mime.plain" label: "Plain text" keys: [] target: "mime" require: "always" groupStart: false}
      {action: "set-mime.markdown" label: "Markdown" keys: [] target: "mime" require: "always" groupStart: false}
    ]
  }
  let trash_row = if $ctx.hasDeleted {
    [{action: "trash.open" label: "Trash" keys: (glyphs [Shift T]) target: "stack" require: "always"}]
  } else { [] }
  let items = ([
    {action: "clip.new" label: "New clip" keys: (glyphs [N]) target: "clip" require: "stack"}
    {action: "clip.edit" label: "Edit clip" keys: (glyphs [E]) target: "clip" require: "clip"}
    {action: "clip.set-mime" label: "Set content type" keys: [] target: "clip" require: "clip"}
    {action: "clip.pipe" label: "Pipe clip" keys: (glyphs [P]) target: "clip" require: "clip"}
    {action: "clip.delete" label: "Delete clip" keys: (glyphs [Del]) target: "clip" require: "clip"}
    {action: "stack.new" label: "New stack" keys: (glyphs [Shift N]) target: "stack" require: "always"}
    {action: "stack.rename" label: "Rename stack" keys: (glyphs [R]) target: "stack" require: "stack"}
    {action: "stack.sort.toggle" label: "Toggle sort" keys: [] target: "stack" require: "stack"}
    {action: "stack.delete" label: "Delete stack" keys: (glyphs [Shift Del]) target: "stack" require: "stack"}
  ] | append $trash_row)
  let visible = $items | where {|x|
      match $x.require {
        "always" => true
        "stack" => ($ctx.selectedStackId != null)
        "clip" => ($ctx.selectedClipId != null)
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
def stack-actions-for [mode: string ctx: record]: nothing -> list {
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
def mode-name-for [mode: string ctx: record]: nothing -> string {
  match $mode {
    "compose" => $"New clip in ($ctx.composeStackName)"
    "edit" => $"Edit clip in ($ctx.editStackName)"
    "rename" => "Rename stack"
    "actions" => "Actions"
    "set-mime" => "Set content type"
    "trash" => "Trash"
    "pipe" => (if $ctx.pipeStackName == "" { "Pipe clip" } else { $"Pipe clip from ($ctx.pipeStackName)" })
    _ => {
      if $ctx.selectedStack == null { "Stacks" } else { ($ctx.selectedStack.name? | default "Untitled") }
    }
  }
}

# Locate a clip across all stacks; returns {clip, stackName} or null.
def find-clip [state: record clip_id: any]: nothing -> any {
  if $clip_id == null { return null }
  for s in $state.stacks {
    let hit = $s.clips | where id == $clip_id | get -i 0
    if $hit != null { return {clip: $hit stackName: $s.name} }
  }
  null
}

# Take the projection state and turn it into the template's view model.
# is_mac selects platform-correct modifier keys/glyphs (Cmd on Mac, Ctrl
# elsewhere). Defaults to true for synthetic callers (design page, tests).
def view-model [state: record --is-mac = true]: nothing -> record {
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
  let pipe_target = find-clip $state $state.pipeClipId
  let pipe_clip = if $pipe_target == null { null } else { hydrate-clip $pipe_target.clip }
  let pipe_stack_name = if $pipe_target == null { "" } else { $pipe_target.stackName }

  # Trash list: hydrate each delete entry into a renderable row. Newest first
  # (state.deleted is already prepended-on-delete). For clip rows, mark
  # `canRestore: false` when the parent stack is itself deleted -- the row is
  # shown but the action no-ops (mirrors projection's clip-restore guard).
  let deleted_items = $state.deleted | each {|entry|
      if $entry.kind == "clip" {
        let parent_id = $entry.snapshot.stack_id
        let parent_stack = $state.stacks | where id == $parent_id | get -i 0
        let parent_in_trash = $state.deleted | any {|e| $e.kind == "stack" and $e.snapshot.stack.id == $parent_id }
        let parent_alive = ($parent_stack != null) and (not $parent_in_trash)
        let p = cas-preview $entry.snapshot.clip.hash? $entry.snapshot.clip.mime_type?
        let preview = $p.preview
        {
          frame_id: $entry.frame_id
          kind: "clip"
          icon: "lucide:file-text"
          label: (if ($preview | is-empty) { "(empty)" } else { $preview })
          sublabel: (if $parent_stack != null { $parent_stack.name? | default "Untitled" } else { "(deleted stack)" })
          canRestore: $parent_alive
        }
      } else {
        let s = $entry.snapshot.stack
        {
          frame_id: $entry.frame_id
          kind: "stack"
          icon: "lucide:layers"
          label: ($s.name? | default "Untitled")
          sublabel: $"($s.clips | length) clip\(s\)"
          canRestore: true
        }
      }
    }
  let has_deleted = (not ($deleted_items | is-empty))
  # Default selection in trash mode: first row, when nothing is selected yet.
  let selected_deleted = if $state.mode == "trash" and $state.selectedDeletedFrameId == null and $has_deleted {
    $deleted_items | first | get frame_id
  } else {
    $state.selectedDeletedFrameId
  }

  let ctx = {
    composeStackId: $state.composeStackId
    composeStackName: $compose_name
    editClipId: $state.editClipId
    editStackName: $edit_name
    renameStackId: $state.renameStackId
    setMimeClipId: $state.setMimeClipId
    selectedStackId: $state.selectedStackId
    selectedClipId: $state.selectedClipId
    selectedStack: $stack
    selectedDeletedFrameId: $selected_deleted
    hasDeleted: $has_deleted
    isMac: $is_mac
    pipeClipId: $state.pipeClipId
    pipeStackName: $pipe_stack_name
    pipeHistoryOpen: $state.pipeHistoryOpen
    pipeFiltered: (projection pipe-filtered $state)
    pipeHistoryCursor: $state.pipeHistoryCursor
  }
  let actions = actions-for $state.mode $ctx
  let keymap = keymap-for $state.mode $ctx
  let bindings = bindings-for $state.mode $ctx
  let stack_actions = stack-actions-for $state.mode $ctx
  let panel_actions = panel-actions-for $state.mode $ctx
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
    deletedItems: $deleted_items
    selectedDeletedFrameId: $selected_deleted
    pipeClipId: $state.pipeClipId
    pipeClip: $pipe_clip
    pipeStackName: $pipe_stack_name
    pipeResult: $state.pipeResult
    pipeText: $state.pipeText
    pipeHistoryOpen: $state.pipeHistoryOpen
    pipeHistoryCursor: $state.pipeHistoryCursor
    pipeFiltered: (projection pipe-filtered $state)
    actions: ($actions | to json -r)
    keymap: ($keymap | to json -r)
  }
}

def render-event [state: record --is-mac = true]: nothing -> list {
  let html = view-model $state --is-mac=$is_mac | .mj ($script_dir | path join "templates/three-pane.html.j2")
  let elements = $html | lines | each {|l| $"elements ($l)" } | str join "\n"
  let html_event = {event: "datastar-patch-elements" data: $"selector main\n($elements)"}
  # Emit a forced signal patch when pipeText was just set server-side
  # (history.select / pipe.open / pipe.close). Typing fires pipe.text,
  # which we deliberately exclude so the user's keystrokes aren't
  # clobbered by the server's stale value.
  let force_signal = ($state._lastTopic? | default "") in [
    "pipe.history.select"
    "pipe.open"
    "pipe.close"
  ]
  if $force_signal {
    let signal_event = {pipeText: $state.pipeText} | to datastar-patch-signals
    [$signal_event $html_event]
  } else {
    [$html_event]
  }
}

# Synthetic state for the /design page. Same shape projection produces, but
# hand-rolled so we can vary the mode without driving a live store.
def design-state [variant: string]: nothing -> record {
  let stacks = [
    {
      id: "s1"
      name: "Inbox"
      sort: "auto"
      lastTouched: "f3"
      clips: [
        {
          id: "c1"
          hash: "fake-h1"
          mime_type: "text/plain"
          position: null
          lastTouched: "c1"
          versions: ["c1"]
          body: "We invent the future a few times a year, in the kitchen, around the table.\nThe rest is execution."
        }
        {
          id: "c2"
          hash: "fake-h2"
          mime_type: "text/plain"
          position: null
          lastTouched: "c2"
          versions: ["c2"]
          body: "ssh deploy@vm 'tail -f /var/log/app.log | grep -i error'"
        }
      ]
    }
    {
      id: "s2"
      name: "Snippets"
      sort: "manual"
      lastTouched: "c4"
      clips: [
        {
          id: "c3"
          hash: "fake-h3"
          mime_type: "text/plain"
          position: "a"
          lastTouched: "c3"
          versions: ["c3"]
          body: "ls **/*.nu | each {|f| {file: $f.name lines: (open $f.name | lines | length)}}"
        }
        {
          id: "c4"
          hash: "fake-h4"
          mime_type: "text/plain"
          position: "b"
          lastTouched: "c4"
          versions: ["c4"]
          body: "https://github.com/cablehead/xs"
        }
      ]
    }
    {id: "s3" name: "Untitled" sort: "auto" lastTouched: "s3" clips: []}
  ]
  let base = projection empty
    | update stacks $stacks
    | update selectedStackId "s1"
    | update selectedClipId "c1"
    | update selectionExplicit true
  match $variant {
    "main" => $base
    "main-empty-stack" => ($base | update selectedStackId "s3" | update selectedClipId null)
    "compose" => ($base | update mode "compose" | update composeStackId "s1")
    "edit" => ($base | update mode "edit" | update editClipId "c1")
    "rename" => ($base | update mode "rename" | update renameStackId "s1")
    "actions" => ($base | update mode "actions")
    "set-mime" => ($base | update mode "set-mime" | update setMimeClipId "c1")
    "trash" => ($base
    | update mode "trash"
    | update deleted [
      {
        frame_id: "td1"
        kind: "clip"
        snapshot: {
          clip: {id: "cx" hash: null mime_type: "text/plain" position: null lastTouched: "cx" versions: ["cx"]}
          stack_id: "s1"
        }
        deleted_at: "td1"
      }
      {
        frame_id: "tsd1"
        kind: "stack"
        snapshot: {
          stack: {id: "sx" name: "Old Stack" sort: "auto" lastTouched: "sx" clips: []}
        }
        deleted_at: "tsd1"
      }
    ]
    | update selectedDeletedFrameId "td1")
    "pipe" => ($base
    | update mode "pipe"
    | update pipeClipId "c1"
    | update pipeResult {ok: true body: "PREVIEW OUTPUT" error: null}
    | update pipeHistory ["str upcase" "lines | length" "from json | get name" "where size > 1kb" "$in | str trim"])
    "pipe-error" => ($base
    | update mode "pipe"
    | update pipeClipId "c1"
    | update pipeResult {ok: false body: "" error: "Parse error: missing argument"}
    | update pipeHistory ["str upcase" "from json"])
    "pipe-history" => ($base
    | update mode "pipe"
    | update pipeClipId "c1"
    | update pipeHistoryOpen true
    | update pipeHistoryCursor 0
    | update pipeHistory ["str upcase" "lines | length" "from json | get name" "where size > 1kb" "str trim"])
    _ => $base
  }
}

# Render one mode into a self-contained HTML doc suitable for iframe srcdoc.
# No scripts loaded -- the page is inert; click handlers reference an undefined
# window.actions and silently no-op.
def design-tile-html [variant: string --is-mac = true]: nothing -> string {
  let state = design-state $variant
  let main_html = view-model $state --is-mac=$is_mac | .mj ($script_dir | path join "templates/three-pane.html.j2")
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

def design-page [--is-mac = true]: nothing -> any {
  let variants = ["main" "main-empty-stack" "compose" "edit" "rename" "actions" "set-mime" "trash" "pipe" "pipe-error" "pipe-history"]
  (HTML
  (HEAD
  (META {charset: "utf-8"})
  (TITLE "stacks.nu | design")
  (LINK {rel: "stylesheet" href: "/stellar.css"})
  (LINK {rel: "stylesheet" href: "/base.css"})
  (SCRIPT-ICONIFY))
  (BODY {style: "padding: 1.5rem; background: var(--primary-6); color: var(--primary-6-on); font-family: var(--font-sans); margin: 0; height: 100vh; overflow: auto;"}
  (H1 {style: "font-size: var(--font-size-2); margin: 0 0 .25rem;"} "stacks.nu | design")
  (P {style: "color: var(--primary-7-dim); font-size: var(--font-size--1); margin: 0 0 1.5rem;"}
  "Inert layout previews of every mode. Each tile is an iframe rendering the live template at a fixed state.")
  (DIV {style: "display: grid; grid-template-columns: repeat(auto-fill, minmax(40rem, 1fr)); gap: 1.5rem;"}
  ($variants | each {|v|
    (FIGURE {style: "margin: 0; background: var(--primary-7); border: 1px solid var(--primary-7-dim); border-radius: var(--border-radius-2); overflow: hidden;"}
    (IFRAME {srcdoc: (design-tile-html $v --is-mac=$is_mac) title: $v style: "width: 100%; height: 26rem; border: 0; display: block;"})
    (FIGCAPTION {style: "padding: .5rem .75rem; font-family: var(--font-mono); font-size: var(--font-size--1); color: var(--primary-7-on); border-top: 1px solid var(--primary-7-dim);"} $v))
  }))))
}

def shots-page []: nothing -> any {
  let dir = $script_dir | path join "static/shots"
  let files = if ($dir | path exists) {
    ls $dir | where ($it.name | str ends-with ".png") | get name | each {|p| $p | path basename } | sort
  } else { [] }
  (HTML
  (HEAD
  (META {charset: "utf-8"})
  (TITLE "stacks.nu | screenshots")
  (LINK {rel: "stylesheet" href: "/stellar.css"})
  (LINK {rel: "stylesheet" href: "/base.css"}))
  (BODY {style: "padding: 1.5rem; background: var(--primary-6); color: var(--primary-6-on); font-family: var(--font-sans);"}
  (H1 {style: "font-size: var(--font-size-2); margin: 0 0 1rem;"} "stacks.nu screenshots")
  (P {style: "color: var(--primary-7-dim); font-size: var(--font-size--1); margin: 0 0 1.5rem;"}
  $"($files | length) pose"
  (if ($files | length) == 1 { "" } else { "s" })
  " in "
  (CODE "www/static/shots/"))
  (if ($files | is-empty) {
    (P {style: "color: var(--primary-7-dim);"} "No shots yet. Run "
    (CODE "scripts/shoot.py") " to bake some.")
  } else {
    (DIV {style: "display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 1rem;"}
    ($files | each {|f|
      let slug = $f | str replace ".png" "" | str replace -a "-" " "
      (FIGURE {style: "margin: 0; background: var(--primary-7); border: 1px solid var(--primary-7-dim); border-radius: var(--border-radius-2); overflow: hidden;"}
      (IMG {src: $"/shots/($f)" alt: $slug style: "width: 100%; display: block;"})
      (FIGCAPTION {style: "padding: .5rem .75rem; font-family: var(--font-mono); font-size: var(--font-size--1); color: var(--primary-7-on); border-top: 1px solid var(--primary-7-dim);"} $slug))
    }))
  })))
}

def index-page []: nothing -> any {
  (HTML
  (HEAD
  # Pre-paint theme apply -- runs synchronously before the stylesheet so
  # there's no light->dark flash. localStorage wins; otherwise system pref.
  (SCRIPT {
    __html: "
(function() {
  var saved = localStorage.getItem('theme');
  var dark = saved ? saved === 'dark' : window.matchMedia('(prefers-color-scheme:dark)').matches;
  if (dark) document.documentElement.classList.add('dark');
})();
"
  })
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
  (SCRIPT {
    __html: "
window.toggleTheme = function() {
  var isDark = document.documentElement.classList.toggle('dark');
  localStorage.setItem('theme', isDark ? 'dark' : 'light');
  var icon = document.querySelector('#theme-toggle iconify-icon');
  if (icon) icon.setAttribute('icon', isDark ? 'lucide:sun' : 'lucide:moon');
};
"
  }))
  # Hosting the SSE @get on <main> instead of <body> protects it from
  # Datastar's per-element AbortController if we ever migrate impulses
  # from plain fetch to @post. See post-get-nuance.md for the trap.
  (BODY (MAIN {data-init: "@get('/updates')"} "loading...")))
}

# First-run seed: when the store has never had a stack, drop in two stacks
# whose clips form a guided walkthrough.
#
# Tutorial (top): the spine. Each step's instruction is the natural action to
# advance -- pressing "j" moves you down; DEL preserves cursor slot so it
# lands on the next step; the final "e" demonstrates auto sort by floating
# the edited clip to the top.
#
# Side Quest (below Tutorial): a single-clip detour. The Tutorial sends you
# here via Shift+j; you Shift+DEL the whole stack to bounce back, restoring
# your per-stack cursor on the Tutorial side.
#
# Append order matters: stacks render lastTouched-desc, so Tutorial is
# populated AFTER Side Quest to land on top. Within each stack, clips also
# render newest-first, so we append in reverse display order.
#
# Idempotent -- skipped on every subsequent boot.
def bootstrap-if-empty []: nothing -> nothing {
  if (.cat | where topic == "stack.add" | length) > 0 { return }

  # ---- Side Quest (added first so Tutorial ends up on top) ----
  let side = .append stack.add --meta {name: "Side Quest" sort: "auto"}
  "Welcome to the side quest stack. The Tutorial stack is still in the list on the left.

Press \"Shift+DEL\" to delete this whole stack. Click OK to confirm.

Your cursor will preserve and bounce you back to where you left off in Tutorial."
  | .append clip.add --meta {stack_id: $side.id mime_type: "text/plain"} | ignore

  # ---- Tutorial ----
  let tut = .append stack.add --meta {name: "Tutorial" sort: "auto"}

  # Step 5 -- bottom; press "e" to edit, demonstrates auto sort + graduates.
  "Press \"e\" to edit this clip. \"Cmd+Enter\" saves; Esc cancels.

When you save, you'll bounce to the top of the stack -- that's auto sort: edits float clips up by recency.

There's more in the actions panel:
  \"n\"          new clip in this stack
  \"Shift+n\"    new stack
  \"r\"          rename this stack
  \"Shift+DEL\"  delete this whole stack
  \"0\"          jump to top of stack
  \"Shift+0\"    jump to the first stack

The icon on the far right of the status bar toggles light / dark.

When you're ready to start for real, \"Shift+DEL\" removes this whole stack."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore

  # Step 4 -- continuation after returning from the side quest.
  "Welcome back. Your cursor preserved its position -- and the side quest stack is gone.

Press \"Cmd+k\" to open the actions panel. Type to filter, arrows to navigate, Enter (or click) to fire, Esc to close.

When you're done, press \"j\" to continue."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore

  # Step 3 -- side quest hand-off. Re-read after return tells you to press "j".
  "Side quest: press \"Shift+j\" to switch to the next stack.

When you come back, press \"j\" to continue."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore

  # Step 2 -- press DEL; cursor preservation lands you on what was step 3.
  "Press DEL to delete this clip.

Your cursor stays in the same slot, so you'll land on the next clip down."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore

  # Step 1 -- nav refresher.
  "\"j\" goes to the next clip; \"k\" goes to the previous one.

\"Shift+j\" / \"Shift+k\" cycle stacks (the list on the left).

Press \"j\" again."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore

  # Step 0 -- top; the user's first view.
  "Welcome to stacks.nu.

The status bar at the bottom shows your keys.

Press \"j\" to move to the next clip."
  | .append clip.add --meta {stack_id: $tut.id mime_type: "text/plain"} | ignore
}

bootstrap-if-empty

{|req|
  dispatch $req [
    (route {method: "GET" path: "/"} {|req ctx| index-page })
    (route {method: "GET" path: "/shots"} {|req ctx| shots-page })
    (route {method: "GET" path: "/design"} {|req ctx| design-page --is-mac=(is-mac $req) })

    # Lightweight synchronous state probe -- returns the projection's
    # cursor info as JSON. Used by tooling (e.g. scripts/shoot-design.sh)
    # that needs the currently-selected stack id without subscribing to
    # the streaming /updates SSE.
    (route {method: "GET" path: "/api/state"} {|req ctx|
      let s = .cat | projection project
      {
        selectedStackId: $s.selectedStackId
        selectedClipId: $s.selectedClipId
        stackIds: ($s.stacks | get id)
      }
    })

    (route {method: "GET" path: "/updates"} {|req ctx|
      let is_mac = is-mac $req
      # Persistent frames come from .cat -f (durable history + xs.threshold +
      # live appends). Ephemeral UI signals (selection, mode toggles, pipe
      # input, pipe results) come from .bus -- in-process pub/sub, no
      # persistence, no cross-host wire traffic. We wrap each bus event into
      # a frame-shaped record so apply-frame can fold them uniformly with
      # store frames.
      (null | interleave
      { .cat -f }
      { .bus sub | each {|e| {topic: $e.topic id: (.id) hash: null meta: $e.value} } }) | projection project-stream
      | each {|s| render-event $s --is-mac=$is_mac }
      | flatten
      | to sse
    })

    # ---- ephemeral signal channel ----
    # Pure-injection endpoint for transient state nudges (selection cycling,
    # modal opens/closes). Topic must be in IMPULSE_TOPICS; meta is forwarded
    # verbatim. Persistent mutations (clip.add, clip.update, *.delete, ...)
    # keep their own REST routes -- different trust level, different audit.
    (route {method: "POST" path: "/_impulse"} {|req ctx|
      let body = $in | from json
      let topic = $body.topic? | default ""
      if not ($topic in $IMPULSE_TOPICS) {
        return ("topic not allowed" | metadata set { merge {'http.response': {status: 400}} })
      }
      let meta = $body.meta? | default {}
      $meta | .bus pub $topic
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- compose submit (workflow: clip.add then close mode) ----
    (route {method: "POST" path-matches: "/compose/submit/:id"} {|req ctx|
      let text = $in
      if not ($text | str trim | is-empty) {
        $text | .append clip.add --meta {stack_id: $ctx.id mime_type: "text/plain"} | ignore
      }
      {} | .bus pub compose.close | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- rename submit (workflow: stack.update then close mode) ----
    (route {method: "POST" path-matches: "/stacks/:id/rename/submit"} {|req ctx|
      let name = $in | default "" | str trim
      if not ($name | is-empty) {
        .append stack.update --meta {id: $ctx.id name: $name} | ignore
      }
      {} | .bus pub rename.close | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- editor submit (workflow: clip.update then close mode) ----
    (route {method: "POST" path-matches: "/editor/submit/:id"} {|req ctx|
      let text = $in
      if not ($text | str trim | is-empty) {
        # clip.update keeps the clip's identity stable -- selection, position,
        # mime type all stay attached to the same id. Prior content lives on
        # in the event log under the original clip.add and any earlier
        # clip.update frames.
        $text | .append clip.update --meta {id: $ctx.id} | ignore
      }
      {} | .bus pub editor.close | ignore
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
      {id: $frame.id} | .bus pub stack.select | ignore
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
      # Field-level patch: stack_id moves, position repositions, mime_type
      # re-classifies. Validate mime_type against the small allowlist; pass
      # the rest through.
      let body = $in | from json
      let mime_ok = ["text/plain" "text/markdown"]
      if "mime_type" in ($body | columns) and not ($body.mime_type in $mime_ok) {
        return ("invalid mime_type" | metadata set { merge {'http.response': {status: 400}} })
      }
      .append clip.patch --meta ($body | merge {id: $ctx.id}) | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "DELETE" path-matches: "/clips/:id"} {|req ctx|
      .append clip.delete --meta {id: $ctx.id}
    })

    # ---- trash ----
    # Restore a deleted entity. The path id is the original delete frame's id;
    # we look it up to dispatch on whether it was a clip or stack delete, then
    # emit the matching restore topic. For clip restores we project current
    # state and refuse when the parent stack is itself in trash -- the
    # projection would silently no-op, leaving the user wondering.
    (route {method: "POST" path-matches: "/trash/restore/:frame_id"} {|req ctx|
      let frame = .get $ctx.frame_id
      if $frame == null {
        return ("Not Found" | metadata set { merge {'http.response': {status: 404}} })
      }
      match $frame.topic {
        "clip.delete" => {
          let state = .cat | projection project
          let entry = $state.deleted | where frame_id == $ctx.frame_id | get -i 0
          if $entry == null {
            return ("clip already restored" | metadata set { merge {'http.response': {status: 409}} })
          }
          let parent_alive = ($state.stacks | any {|s| $s.id == $entry.snapshot.stack_id })
          if not $parent_alive {
            return ("parent stack is in trash; restore the stack first" | metadata set { merge {'http.response': {status: 409}} })
          }
          .append clip.restore --meta {target: $ctx.frame_id} | ignore
        }
        "stack.delete" => { .append stack.restore --meta {target: $ctx.frame_id} | ignore }
        _ => { return ("frame is not a delete" | metadata set { merge {'http.response': {status: 400}} }) }
      }
      {} | .bus pub trash.close | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- pipe ----
    # Run a user-supplied nushell pipeline against the clip's body. Result
    # (or error) is recorded as an ephemeral pipe.result frame; the
    # projection picks it up and the SSE stream re-renders the result pane.
    # Bound signal sync. The input has data-bind="pipeText" so each typing
    # event POSTs the signals payload here; we extract the value and append
    # an ephemeral pipe.text frame. Projection fold updates pipeText, the
    # popup re-renders with the filtered list.
    (route {method: "POST" path: "/pipe/text"} {|req ctx|
      let signals = $in | from datastar-signals $req
      let value = $signals.pipeText? | default ""
      {value: $value} | .bus pub pipe.text | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })
    (route {method: "POST" path-matches: "/pipe/run/:clip_id"} {|req ctx|
      let pipeline = $in
      let frame = .get $ctx.clip_id
      if $frame == null {
        return ("Not Found" | metadata set { merge {'http.response': {status: 404}} })
      }
      # Record the pipeline source as a persistent frame so it shows up in
      # arrow-key history. The actual run + result follows below.
      if not ($pipeline | str trim | is-empty) {
        .append pipe.command --meta {source: $pipeline clip_id: $ctx.clip_id} | ignore
      }
      let body = if $frame.hash? == null { "" } else { try { .cas $frame.hash } catch { "" } }
      let outcome = try {
        let raw = $body | .run $pipeline | to text
        # Cap at 64KB so a runaway pipeline doesn't push a huge frame meta.
        let cap = 65536
        let result = if ($raw | str length) > $cap {
          ($raw | str substring 0..$cap) + "\n... (truncated)"
        } else { $raw }
        {ok: true body: $result}
      } catch {|e|
        # $e.msg is only the error title (e.g. "Parse error"). The detail
        # lives in $e.json.labels[*].text -- join them onto the title.
        let parsed = try { $e.json | from json } catch { {labels: []} }
        let detail = $parsed.labels? | default [] | get text? | default [] | str join "; "
        let full = if ($detail | is-empty) { $e.msg } else { $"($e.msg): ($detail)" }
        {ok: false body: "" error: $full}
      }
      $outcome | .bus pub pipe.result | ignore
      "" | metadata set { merge {'http.response': {status: 204}} }
    })

    # ---- content + assets ----
    # Content-addressed CAS fetch: URL keyed by content hash, so identical
    # clips dedup at the browser cache layer and we can ship long max-age +
    # immutable. Mime comes via ?type= since the route only has the hash.
    (route {method: "GET" path-matches: "/cas/:hash"} {|req ctx|
      # Strict SRI shape check before calling .cas (the upstream ssri crate
      # panics on malformed input). Only sha256 (44 base64 chars) and
      # sha512 (88 base64 chars) are accepted; that's what xs emits today.
      let parts = $ctx.hash | split row "-"
      let valid = (($parts | length) == 2) and (($parts.0 == "sha256" and (($parts.1 | str length) == 44)) or
      ($parts.0 == "sha512" and (($parts.1 | str length) == 88)))
      if not $valid {
        return ("Not Found" | metadata set { merge {'http.response': {status: 404}} })
      }
      let mime = $req.query?.type? | default "application/octet-stream"
      try {
        .cas $ctx.hash | metadata set {
          merge {
            'http.response': {
              headers: {
                "Content-Type": $mime
                "Cache-Control": "public, max-age=31536000, immutable"
              }
            }
          }
        }
      } catch {
        "Not Found" | metadata set { merge {'http.response': {status: 404}} }
      }
    })
    # Legacy: keyed by frame id, no caching guarantees. Kept for backwards
    # compat with any external consumers; new template references use /cas.
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
