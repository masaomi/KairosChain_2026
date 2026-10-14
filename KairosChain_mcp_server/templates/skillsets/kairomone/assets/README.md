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
