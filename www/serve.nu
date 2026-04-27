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
}

def glyphs [keys: list<string>]: nothing -> list<string> {
  $keys | each {|k| $KEY_GLYPH | get -i $k | default $k }
}

# Single source of truth for "what keys exist in this mode" -- drives both
# the data-keymap (for keys.js) and the status bar (for the user). Each
# binding has a combo string (matching keys.js's `cmd+ctrl+alt+shift+key`
# normalization), a short label, displayable key glyphs, and the action
# (URL string or {url, source} record).
def bindings-for [mode: string, ctx: record]: nothing -> list {
  match $mode {
    "compose" => [
      {combo: "cmd+enter" label: "save"   keys: (glyphs [Cmd Enter]) action: {url: $"/compose/submit/($ctx.composeStackId)" source: "#compose-text"}}
      {combo: "escape"    label: "cancel" keys: (glyphs [Esc])       action: "/compose/cancel"}
    ]
    "edit" => [
      {combo: "cmd+enter" label: "save"   keys: (glyphs [Cmd Enter]) action: {url: $"/editor/submit/($ctx.editClipId)" source: "#compose-text"}}
      {combo: "escape"    label: "cancel" keys: (glyphs [Esc])       action: "/editor/cancel"}
    ]
    _ => {
      let core = [
        {combo: "j"       label: "next clip"   keys: (glyphs [J])       action: "/select/clip/down"}
        {combo: "k"       label: "prev clip"   keys: (glyphs [K])       action: "/select/clip/up"}
        {combo: "shift+j" label: "next stack"  keys: (glyphs [Shift J]) action: "/select/stack/down"}
        {combo: "shift+k" label: "prev stack"  keys: (glyphs [Shift K]) action: "/select/stack/up"}
        {combo: "shift+n" label: "new stack"   keys: (glyphs [Shift N]) action: "/stacks/new"}
      ]
      # `n` and `e` only bind when there's a target -- the URL carries the
      # id so handlers don't re-derive from ephemeral state (which a fresh
      # `.cat` snapshot can't see).
      let with_n = if $ctx.selectedStackId != null {
        $core | append {combo: "n" label: "new clip" keys: (glyphs [N]) action: $"/compose/open/($ctx.selectedStackId)"}
      } else { $core }
      if $ctx.selectedClipId != null {
        $with_n | append {combo: "e" label: "edit clip" keys: (glyphs [E]) action: $"/editor/open/($ctx.selectedClipId)"}
      } else { $with_n }
    }
  }
}

# Stack-related affordances shown on the LEFT of the status bar in main mode.
# Each is {label, icon, url} -- icon is an iconify name; url is POSTed on
# mousedown. Empty list when there's no useful target.
def stack-actions-for [mode: string, ctx: record]: nothing -> list {
  if $mode != "main" { return [] }
  let stack = $ctx.selectedStack
  if $stack == null { return [] }
  let next_sort = if $stack.sort == "auto" { "manual" } else { "auto" }
  let sort_icon = if $stack.sort == "auto" {
    "lucide:arrow-down-narrow-wide"
  } else {
    "lucide:list-ordered"
  }
  [
    {label: $"sort: ($stack.sort)" icon: $sort_icon url: $"/stacks/($stack.id)/sort/($next_sort)"}
  ]
}

# What goes on the LEFT of the status bar -- the stack name in main mode,
# the modal title elsewhere.
def mode-name-for [mode: string, ctx: record]: nothing -> string {
  match $mode {
    "compose" => $"New clip in ($ctx.composeStackName)"
    "edit" => $"Edit clip in ($ctx.editStackName)"
    _ => {
      if $ctx.selectedStack == null { "Stacks" } else { $ctx.selectedStack.name }
    }
  }
}

# Pack the bindings list into the `{combo: action}` json that keys.js reads.
def keymap-for [bindings: list]: nothing -> string {
  $bindings | reduce -f {} {|b, acc| $acc | upsert $b.combo $b.action } | to json -r
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
  let ctx = {
    composeStackId: $state.composeStackId
    composeStackName: $compose_name
    editClipId: $state.editClipId
    editStackName: $edit_name
    selectedStackId: $state.selectedStackId
    selectedClipId: $state.selectedClipId
    selectedStack: $stack
  }
  let bindings = bindings-for $state.mode $ctx
  let stack_actions = stack-actions-for $state.mode $ctx
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
    bindings: $bindings
    stackActions: $stack_actions
    keymap: (keymap-for $bindings)
  }
}

def render-event [state: record]: nothing -> record {
  let html = view-model $state | .mj ($script_dir | path join "templates/three-pane.html.j2")
  let elements = $html | lines | each {|l| $"elements ($l)" } | str join "\n"
  {event: "datastar-patch-elements" data: $"selector main\n($elements)"}
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
      (LINK {rel: "stylesheet" href: "http://localhost:7331/assets/css/stellar"})
      (LINK {rel: "stylesheet" href: "/base.css"})
    )
    (
      BODY {style: "padding: 1.5rem; background: var(--neutral-1); color: var(--neutral-1-on); font-family: var(--font-sans);"}
      (H1 {style: "font-size: var(--font-size-2); margin: 0 0 1rem;"} "stacks.nu screenshots")
      (P {style: "color: var(--neutral-2-dim); font-size: var(--font-size--1); margin: 0 0 1.5rem;"}
        $"($files | length) pose"
        (if ($files | length) == 1 { "" } else { "s" })
        " in "
        (CODE "www/static/shots/")
      )
      (if ($files | is-empty) {
        (P {style: "color: var(--neutral-2-dim);"} "No shots yet. Run "
          (CODE "scripts/shoot.py") " to bake some.")
      } else {
        (
          DIV {style: "display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 1rem;"}
          ($files | each {|f|
            let slug = $f | str replace ".png" "" | str replace -a "-" " "
            (FIGURE {style: "margin: 0; background: var(--neutral-2); border: 1px solid var(--neutral-3); border-radius: var(--border-radius-2); overflow: hidden;"}
              (IMG {src: $"/shots/($f)" alt: $slug style: "width: 100%; display: block;"})
              (FIGCAPTION {style: "padding: .5rem .75rem; font-family: var(--font-mono); font-size: var(--font-size--1); color: var(--neutral-2-on); border-top: 1px solid var(--neutral-3);"} $slug)
            )
          })
        )
      })
    )
  )
}

def index-page []: nothing -> any {
  # Path is fixed by `http-nu --datastar`; we hardcode it here so the page
  # is also renderable from `http-nu eval` (no --datastar; no $DATASTAR_JS_PATH).
  (
    HTML
    (
      HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport" content: "width=device-width,initial-scale=1"})
      (TITLE "stacks.nu")
      (LINK {rel: "stylesheet" href: "http://localhost:7331/assets/css/stellar"})
      (LINK {rel: "stylesheet" href: "/base.css"})
      (SCRIPT {type: "module" src: "/datastar@1.0.0-RC.8.js"})
      (SCRIPT-ICONIFY)
      (SCRIPT {src: "/keys.js"})
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
      # Bare-keymap action: create a stack with a default timestamp name and
      # select it. Rename comes via PATCH /stacks/:id.
      let name = date now | format date "%Y-%m-%d %H:%M"
      let frame = .append stack.add --meta {name: $name sort: "auto"}
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
