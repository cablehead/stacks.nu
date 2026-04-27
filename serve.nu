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

use ./projection.nu

# Decorate a clip with a one-line preview and (when small) the inlined body.
def hydrate-clip [clip: record]: nothing -> record {
  let body = if $clip.hash == null { "" } else {
    try { .cas $clip.hash } catch { "" }
  }
  let preview = $body | str replace -ar "\\s+" " " | str trim | str substring 0..120
  $clip | insert preview $preview | insert body $body
}

# Take the projection state and turn it into the template's view model.
def view-model [state: record]: nothing -> record {
  let stack = $state.stacks | where id == $state.selectedStackId | get -i 0
  let raw_clips = if $stack == null { [] } else { projection sorted-clips $stack }
  let clips = $raw_clips | each {|c| hydrate-clip $c }
  let selected = $clips | where id == $state.selectedClipId | get -i 0
  {
    stacks: $state.stacks
    selectedStackId: $state.selectedStackId
    selectedClipId: $state.selectedClipId
    clips: $clips
    selectedClip: $selected
  }
}

def render-event [state: record]: nothing -> record {
  let html = view-model $state | .mj ($script_dir | path join "templates/three-pane.html.j2")
  let elements = $html | lines | each {|l| $"elements ($l)" } | str join "\n"
  {event: "datastar-patch-elements" data: $"selector main\n($elements)"}
}

def index-page []: nothing -> any {
  # Path is fixed by `http-nu --datastar`. We don't read $DATASTAR_JS_PATH
  # here so the page is also renderable from `http-nu eval` (no --datastar).
  {datastar_js_path: "/datastar@1.0.0-RC.8.js"}
  | .mj ($script_dir | path join "templates/index.html.j2")
}

{|req|
  dispatch $req [
    (route {method: "GET" path: "/"} {|req ctx| index-page })

    (route {method: "GET" path: "/updates"} {|req ctx|
      # `-p` enables xs.threshold + xs.pulse heartbeats; the projection
      # filters pulse out, but threshold is what flips us into "live" mode.
      .cat -f -p 5000
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

    # ---- mutations ----
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
      .static ($script_dir | path join "www") $req.path
    })

    (route true {|req ctx|
      "Not Found" | metadata set { merge {'http.response': {status: 404}} }
    })
  ]
}
