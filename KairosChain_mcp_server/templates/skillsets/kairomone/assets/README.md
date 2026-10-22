# Local status snapshot

`status.html` is a self-contained offline template. It is not a hosted Site and
has no login, network requests, external fonts, storage, polling or live data.
The only controls are language switching and disclosure of included record
titles. The original inline SVG is a small abstract moss creature.

## Renderer contract

Replace the single `__KAIROMONE_STATUS_JSON__` marker inside the
`application/json` script with serialized schema-version-1 status data. Escape
`<`, `>`, `&`, U+2028 and U+2029 as JSON Unicode escapes **before** insertion.
Use a replacement block/callback so payload backslashes remain literal.
Never interpolate data into the surrounding markup or executable script.

The executable script has a SHA-256 Content Security Policy hash. If its bytes
change, regenerate that hash; do not weaken `script-src` to `unsafe-inline`.
The JSON payload does not affect the executable-script hash.

Schema fields consumed:

- `schema_version: 1`, `generated_at`, `initialized`
- `profile.display_name`
- `knowledge: { available, count, items: [{ id, title, snippet? }] }`
- `observations: { available, count, recent: [{ id, title, created_at, snippet? }] }`
- `integrity: { state, valid, block_count, pending_count, details: [] }`
- `backup: { scope: [], excluded: [] }`
- `instructions: { refresh, cli }`

Counts are displayed only for explicitly available stores with nonnegative
safe-integer counts. Unknown data is never presented as zero. L1/L2 must refer
to the dedicated canonical stores, not host-wide counts. An integrity pass
requires exactly `state: "readable"` and `valid: true`. Neither a chain pass nor
backup scope means independent authenticity, truth, or a successful backup.
Record titles are limited to 50 displayed entries; the reported store count
remains the actual count. Every dynamic string uses `textContent`. Source data
is preserved verbatim; changing the UI language does not translate source
record titles or verification details.

## Development checks

- `ruby test_kairomone_ui.rb` from `KairosChain_mcp_server/` tests the production
  renderer, hostile JSON round trips, output location/mode and CSP digest.
- `node templates/skillsets/kairomone/assets/test_status_ui.mjs` runs standalone
  dependency-free syntax, offline-resource, DOM text-sink, JA/EN, availability,
  integrity-state and malformed-data checks.
- `fixtures/status_xss.json` contains **synthetic test data only**, including
  script-closing tags, event-handler text, angle brackets, ampersands and Unicode
  line separators. It is not a user profile and not evidence of a verified
  chain. Never install it as runtime state.

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
| `GET /status` | — | 200 `{"data_dir","status"}`; `status` is the schema-version-1 object |
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
