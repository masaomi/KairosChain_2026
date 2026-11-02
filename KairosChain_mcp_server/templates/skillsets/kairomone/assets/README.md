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
written to the instance or rendered with data. It writes nothing itself:
every control places text in the message box for the owner to read, change
and send, and the hosted session does what that text asks.

## Starting it

The owner runs it at a terminal in the project folder, directly or through
the CLI's `console` subcommand (which runs the same script, given the Ruby
load path it was given):

    ruby .kairos/skillsets/kairomone/scripts/kairomone.rb console [--open [--detach] | --stop] [--project DIR]
    ruby .kairos/skillsets/kairomone/scripts/kairomone_console.rb [--project DIR] [--port N] [--resume ID] [--claude PATH] [--open [--detach] | --stop]

- Without `--open` it stays in the foreground and prints the one-time URL at
  the owner's terminal, as in 0.8; Enter prints a new one (the open page is
  signed out), Ctrl-C stops. Not for Claude Code's `!`: the URL would enter the
  session's context.
- `--open` hands the URL to the system browser (macOS `open`, else
  `xdg-open`) as its one argument, with no shell, and prints only that it
  opened; the launcher's own output goes nowhere. If the browser cannot be
  launched, the console stops and says so, without the URL. In the foreground,
  Enter hands a new URL to the browser.
- `--detach` is accepted only with `--open`. The console then continues in a
  process of its own session that keeps none of the starting process's
  descriptors, so the starting process (and a `!` reading it) ends at once,
  after printing one line: opened (with the stop command), or why not. The
  detached console's standard output and error go to
  `.kairos/run/kairomone_console_detached.log` only through a filter that
  drops any line holding a value its secret ever issued (bootstrap or
  session) or the shape `127.0.0.1:<port>/#`. A new URL means `--stop` and
  start again.
- `--stop` signals (TERM) the PID the console recorded in its lock
  (`.kairos/run/kairomone_console.lock`), only while that lock is held and only
  when that process's command line is a Ruby running `kairomone_console.rb`;
  otherwise it refuses and signals nothing.
- From Claude Code the owner types
  `! ruby .kairos/skillsets/kairomone/scripts/kairomone.rb console --open --detach`;
  the assistant hands that line and never runs it.

In every `--open` combination no start URL or session secret reaches
standard output, standard error, a log or a pipe. The session log
(`kairomone_console.log`) passes the same filter in every mode. The URL is
still visible, for the instant before the page spends it, to a same-user
process reading the launcher's arguments.

For tests only: `KAIROMONE_CONSOLE_BROWSER` names the program `--open` hands
the URL to, the same way `KAIROMONE_CONSOLE_CLAUDE` names the claude
executable; it selects no more than `PATH` would, from the same environment,
and the owner has no reason to set it.

## Layout

- Left: the individual shown — its drawing (an image only), name, the form
  its drawing names, stage, level, profession (「まだ職業はない」 when
  `status.profession.current` is null), XP, chat memory, L1 and L2; its lean
  (the subjects in force and the owner's words the latest change quoted, with
  a control placing the request to clear it); the skills in force; the record
  state (integrity, host L0, paths).
- Centre: the conversation. Each reply is shown with the drawing of the
  individual its message named; permission requests and the composer with its
  four quick requests below.
- Right: the learn panel (a cycle count with 「学習を始める」, a stop control,
  the live run's used / maximum / remaining, lifetime cycles, the operator
  limit only when one is declared, learned subjects); the drawing history in
  the order accepted (a drawing absent or failing the check is shown as
  missing, one accepted before 0.9 by its stage); what waits (drawings,
  profiles, professions and skills, and the open branch offer); the skills
  panel (a request to draft a skill from a named own growth entry); the
  export preview; the creation panel (kind, traits, ID, free text — no
  profession); notes. The page never names a branch level or what a branch
  holds, and offers no fixed profession list.

## What the page sends

Every message the page sends begins with one line naming the listing ID of
the individual shown, which the page adds when sending:

    [Kairomone: <listing ID>]

or `[Kairomone: (none shown)]` when the host lists none. The box opens only
once the first status answer has come, so the line names what the page
shows. Switching individuals changes only what the page shows and the ID the
line and the placed texts name; a placed text left untouched since it was
placed goes with the switch, and what the owner typed stays.

What each control places (`{who}` is `Kairomone「<name>」（識別子: <listing ID>）`;
none carries acceptance, choice or consent wording or a branch level):

| Control | Placed text |
|---|---|
| quick: state | `{who}のいまの状態を教えて` |
| quick: recent | `{who}が最近覚えたことを見せて` |
| quick: one topic | `{who}に〈話題〉について 1 回学習させて` |
| quick: backup | `{who}のバックアップを取って、検証して` |
| 学習を始める (N cycles, 1–999) | `{who}、{N}回学習して` |
| 学習を止める | `{who}の学習を止めて` |
| 傾きを消す | `{who}の傾きを消して` |
| skill draft | `{who}の学んだ知識「{title}」（{entry ID}、sha256: {hash}）から、スキルの案を作って全部見せて` |
| a waiting profile, profession or skill | `{who}の{プロフィール\|職業\|スキル}の案 {proposal}（中身の sha256: {hash}）を全部見せて` |
| a waiting drawing | `{who}の絵の案 {proposal}（絵の sha256: {hash}）を見せて` |
| an offer candidate | `{who}の職業の候補（offer {offer}）の {n} 番目「{name}」で、学び方がどう変わるか教えて` |
| export preview | `{who}を書き出す前の下見を見せて。入れる知識の種類: {kinds}` |
| new Kairomone | `新しい Kairomone の案を作って。種類: {kind}。性格・好きなこと: {traits}。識別子: {id}。ほかに: {free}。プロフィールの案を全部見せて` |

## Page contract

- Exactly one `<style>` and one `<script>` element; no other script, no inline
  event handler or style attribute, no external resource. Every dynamic string
  goes through `textContent`. Every image gets its source in one place, and
  only from a `data:image/svg+xml;base64,` value; drawings are never markup.
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
| `GET /status?kairomone=<listing ID>` | — | 200 `{"data_dir","kairomones","shown","kinds","status","waiting","lean","skills","own_growth","own_growth_total","lifetime_cycles","lifetime_unknown","learned_subjects","art_history"}`: every individual the host lists, the one shown (the one named, else the first), its schema-version-1 `status`, and `waiting` — its drawing as a `data:` image with its form, the drawings, profiles, professions and skills waiting for the owner with their proposal IDs and hashes, and the open branch offer (each candidate's name and description); `lean` `{subjects, owner_words, request_id}`; `skills` in force `{sha256, name, description, methods, focus}`; `own_growth` — the newest 50 own growth entries `{entry_id, sha256, title}`, newest first, of `own_growth_total`; `lifetime_cycles` (null with `lifetime_unknown` `{reason, at_least}` when it cannot be established) and `learned_subjects`; `art_history` `{digest, count}`. No fixed profession list and no branch level. 400 for a malformed ID. An ID the host does not list shows the first listed, with `notice` saying so. Without a listed individual, `shown` is null, `status` says not initialized and the per-individual keys are absent. When what waits cannot be read, `waiting` is null; when the lean, skills and history cannot be read, those keys are null; `error` says why. When the shown individual cannot be read at all, `kairomones` still lists every individual, `shown` and `status` are null and `error` says why |
| `GET /art-history?kairomone=<listing ID>` | — | 200 `{"shown","digest","drawings"}`: every accepted drawing in the order accepted `{sha256, stage, stage_name, form, level, milestone, present, valid, missing, data_uri}` (`level` and `milestone` only where its record holds them; `data_uri` only for one that passes the art check now), and the digest `/status` names for it. The page reads it once per load and again only when that digest changes. An ID the host does not list: `shown`, `digest` and `drawings` null and `error`. 400 without a well-formed ID |
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
