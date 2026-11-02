# Local status snapshot

`status.html` is the snapshot page: a self-contained, offline, view-only page
the owner can hand to friends who cannot run commands (design 0.9 Inv 10, N6).
`kairomone_status(render_html: true)` and `scripts/kairomone.rb status --html`
write it at the Kairomone's fixed `exports/status.html` (mode 0600). Both still
return the full status to their caller; the page carries only what
`Instance#status_public` assembles. It is not a hosted Site: no login, network
request, external font, storage, polling, live data, link, form or input. The
only controls are the JA/EN switch (Japanese by default) and the disclosure of
each cycle's synthesis. It is a picture of one moment and is never synced.

## What the page carries

Only the public subset: what the individual publicly is and what each of its
own growth cycles learned. Never a cycle's request or its topic, any other
entry (owner-written, received or inherited), chat, the direction, the lean,
skills or their sources, a waiting proposal, profile text beyond the name, a
local path or anything secret. Every text — a drawing's markup included, since
its title and desc are readable by whoever holds the file — passes the
credential guard and a local-path check (`/Users/`, `/home/`, `~/`, `file:`,
and this host's own directory) when the page is written; one that fails is left
out and counted in `withheld`, and the page says how many were left out.

Sections, in order: header (title, JA/EN); hero (the current drawing as an
image, the name, stage and level, the line that the level measures stored
records and not ability or feeling, and when the snapshot was written); a
withheld note when `withheld` > 0; drawing history (every accepted drawing in
the order accepted, labelled by its level, or by its stage for a drawing
recorded before 0.9; one absent or failing a check is shown as missing, never as
another); stat cards (lifetime cycles, learned sources, own growth L1 and L2);
profession (its name, or 「まだ職業はない」 / "No profession yet", and lineage
names nearest first); one card per own growth cycle, newest first (its learned
subject names as its label, knowledge title, finding, the synthesis behind a
disclosure, and source addresses as text, not links); and what the snapshot
shows, never shows and promises.

## Renderer contract

Replace the single `__KAIROMONE_STATUS_JSON__` marker inside the
`application/json` script with the serialized `status_public` value. Escape
`<`, `>`, `&`, U+2028 and U+2029 as JSON Unicode escapes **before** insertion.
Use a replacement block/callback so payload backslashes remain literal.
Never interpolate data into the surrounding markup or executable script.

The executable script and the one style element are each pinned by a SHA-256
hash in the Content-Security-Policy meta (`default-src 'none'`, `connect-src
'none'`, `img-src data:`, no `unsafe-inline`). If either element's bytes change,
regenerate its hash; the JSON payload affects neither. From this directory:

    ruby -rdigest -rbase64 -e 'h = File.read(ARGV[0]); %w[script style].each { |t| puts "#{t}-src sha256-" + Base64.strict_encode64(Digest::SHA256.digest(h[%r{<#{t}>(.*?)</#{t}>}m, 1])) }' status.html

Because the style is pinned, the markup holds no `style` attribute. Every
dynamic string goes through `textContent`; images are set only from
`data:image/svg+xml;base64,` URIs; the script creates no link, form or input.

Schema `kairomone-snapshot-1` fields consumed:

- `schema` (any other value, or no object, shows the read error and nothing
  else), `version`, `generated_at`
- `name`, `level` (1–999), `stage: { id, en, ja }`
- `drawing: { shown: "egg" | "drawing", data_uri?, form? }`; `shown: "drawing"`
  without `data_uri` is a drawing left out by the check
- `drawings: [{ data_uri?, missing, form?, stage?: { id, en, ja }, level?,
  milestone? }]`, at most the newest 30, oldest first
- `profession: { chosen, name, lineage: [name] }`; `chosen: false` is no
  profession yet, `chosen: true` with `name: null` is a name left out
- `counts: { lifetime_cycles, learned_sources, own_growth_l1, own_growth_l2 }`;
  `lifetime_cycles` is null when it cannot be established
- `cycles: [{ subjects: [{ id, en, ja }], title, synthesis, finding, sources:
  [url] }]`, at most the newest 100, newest first
- `withheld`: how many texts and drawings were left out

Counts are displayed only as nonnegative safe integers; unknown is never
presented as zero. Source data is preserved verbatim; the language switch
translates only the page's own words, never a name, title, finding or address.

## Development checks

- `ruby test_kairomone_ui.rb` from `KairosChain_mcp_server/` tests the production
  renderer, hostile JSON round trips, output location/mode, both CSP digests,
  that the written page holds exactly `status_public`, and that the page written
  for a crafted individual holds no topic, direction, lean, chat, owner-written
  entry, skill, waiting drawing, retrieval reference or local path.
- `ruby test_kairomone_09_snapshot.rb` tests the public subset itself.
- `node templates/skillsets/kairomone/assets/test_status_ui.mjs` runs standalone
  dependency-free syntax, offline-resource, DOM text-sink, JA/EN, section,
  bounds, unknown-count and malformed-data checks.
- `KAIROMONE_BROWSER_QA=1 node templates/skillsets/kairomone/assets/test_status_browser.mjs`
  is the optional Chromium check (widths, disclosure, CSP, no requests); it
  needs Playwright and a Chromium and skips otherwise.
- `fixtures/status_xss.json` contains **synthetic test data only**, including
  script-closing tags, event-handler text, angle brackets, ampersands and Unicode
  line separators. It is not an individual's snapshot. Never install it as
  runtime state.

The DOM harness is not a browser. CSS contains narrow-screen safeguards,
44-pixel controls, visible focus states and long-string wrapping, but real
320-pixel, tablet and desktop visual checks should be performed in a supported
browser before claiming browser-level verification. No browser installation is
needed by the runtime or these tests.

# Owner console page

`console.html` is served only by `scripts/kairomone_console.rb`, at `GET /` on
`127.0.0.1`. Unlike `status.html` it is live: it long-polls the console and
sends the owner's messages, permission answers and mode changes. It is never
written to the instance or rendered with data.

## Page contract

- Exactly one `<style>` and one `<script>` element; no other script, no inline
  event handler or style attribute, no external resource. Every dynamic string
  goes through `textContent`.
- The console reads the page once when it starts and pins both elements by
  SHA-256 in its Content-Security-Policy, hashed over the element text as a
  browser parses it (CR and CRLF become LF). Editing either element needs no
  hash update; a second `<script>` or `<style>` makes the console refuse to start.
- Bootstrap: the start URL is `http://127.0.0.1:<port>/#<bootstrap>`. The page
  removes the fragment with `history.replaceState`, posts it once as the
  `X-Kairomone-Bootstrap` header, and keeps the returned session secret in
  `sessionStorage`. It sends that secret as `X-Kairomone-Session` on every later
  request. No cookie is used.

## Console contract

Every response carries `Content-Security-Policy: default-src 'none'; script-src
'sha256-…'; style-src 'sha256-…'; connect-src 'self'; img-src 'self' data:;
frame-ancestors 'none'; base-uri 'none'; form-action 'none'`, `X-Frame-Options:
DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`,
`X-Content-Type-Options: nosniff` and `Cross-Origin-Resource-Policy:
same-origin`; never `Set-Cookie` or a CORS header. That includes the answers
WEBrick gives to requests it cannot parse (a path that climbs above the root
once decoded, an over-long URI or header block, a malformed request line); their
body is `{"error":"<reason>"}`, never a page naming the machine or the server
software. A request whose `Host` is not exactly `127.0.0.1:<port>`, a POST whose
`Origin` is not exactly `http://127.0.0.1:<port>`, a request carrying any other
`Origin`, and anything but `GET /` and `POST /session` without a valid session
secret get 403; `OPTIONS *` is no exception. A body over 64 KiB gets 413;
malformed JSON gets 400. Routes are matched on the path as it was sent, before
any decoding: `<request_id>` below is one path segment, written as
`encodeURIComponent` writes it and decoded once.

| Request | Body | Answer |
|---|---|---|
| `GET /` | — | 200, the page |
| `POST /session` | header `X-Kairomone-Bootstrap` | 200 `{"session"}`, or 403 (wrong, spent, or older than 10 minutes) |
| `GET /events?after=<n>` | — | waits up to 25 s; 200 `{"events":[…],"last":<seq>}`, or 403 if the session was revoked while it waited |
| `GET /status?kairomone=<listing ID>` | — | 200 `{"data_dir","kairomones","shown","kinds","templates","status","waiting"}`: every individual the host lists, the one shown (the one named, else the first), its schema-version-1 `status`, and `waiting` — its drawing as a `data:` image, the drawings, profiles and professions waiting for the owner with their proposal IDs and hashes, and the open branch offer; 400 for a malformed ID. An ID the host does not list shows the first listed, with `notice` saying so. Without a listed individual, `shown` is null and `status` says not initialized. When what waits cannot be read, `waiting` is null and `error` says why; when the shown individual cannot be read at all, `kairomones` still lists every individual, `shown` and `status` are null and `error` says why |
| `POST /message` | `{"text"}` | 202 `{"accepted":true}`, or 409 `{"error":"not_accepting","reason"}` |
| `POST /permission/<request_id>` | `{"decision":"allow"\|"deny"}` | 200, 404 (not pending), 409 `answered` (already answered) or `not_allowable` (an allow for a request with `exact: false`) |
| `POST /mode` | `{"mode":"auto"\|"ask"}` | 202, or 409 `{"error":"refused","reason"}` |
| `POST /interrupt` | `{}` | 202 |
| `POST /stop` | `{}` | 202; pending requests are denied and the console ends |

Events are numbered from 1 without gaps and each carries `seq`, `at` and `kind`.
A connection that polls from 0 receives the whole session; a large backlog comes
in parts, so poll again after the last `seq` received. Kinds and fields:
`child_started {session_id, resumed}`, `mode {word, asking, source}` (source
`echo`, `status` or `init`; only the word `default` asks), `accepting {value,
reason}`, `owner_message {text}`, `assistant_text {text}`, `tool_use
{tool_use_id, name, input}`, `permission_request {request_id, tool_use_id,
tool_name, display_name, description, input, exact}`, `permission_answered {request_id,
decision, by}`, `tool_result {tool_use_id, is_error, content, decision,
decision_source, decided_by_page}`, `foreign_turn {text, origin}`, `turn_end
{subtype, is_error}`, `mode_mismatch {expected, reported}`, `child_exited
{status}`, `notice {text}`.

Values the page should expect:

- `accepting.reason`: `mode_unconfirmed`, `turn_in_progress`, `stopped`,
  `memory_cap`. A message can also be refused as `empty`, `too_long` (over 32 KiB)
  or `invalid_text`; a mode change as `invalid_mode`, `stopped`, `not_started` or
  `mode_change_pending`.
- `permission_answered.by`: `owner` (the page), `console_stop` (denied because
  the console stopped) or `console` (denied by a console rule without asking:
  the request came in a turn the console did not start, its id repeats an
  answered one, or Claude Code withdrew it). A `notice` event says which. A
  request whose turn ended stays pending until the owner answers it or the
  console stops.
- `permission_request.exact` is false when the tool name or input holds a value
  JSON cannot carry back unchanged (text that is not UTF-8, a number outside the
  double range, an integer beyond ±(2^53 − 1), which the page's JSON parse
  rounds). Such a request waits like any other but can only be denied,
  because an allow carries back exactly the input shown. In every event, invalid
  bytes are shown as U+FFFD and a number out of range as the text `Infinity`; an
  integer beyond ±(2^53 − 1) stays a JSON number, which the page shows rounded.
- `tool_result.content` is Claude Code's own value: a string or a list of
  content blocks. Show it as text.

The status panel follows the display rules of `status.html` above: unknown is
never shown as zero, and an integrity pass needs `state: "readable"` and
`valid: true`.
