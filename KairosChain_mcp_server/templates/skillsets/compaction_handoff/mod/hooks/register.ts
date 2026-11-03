import type { EngineInterface, Register } from 'claude-code'

// compaction_handoff mod (design log/compaction_handoff_design_v0.4.md, INV-10..14).
// Claude Code layer only. Past the threshold it drives one cycle: ask for the
// handoff as a turn of its own, compact as soon as that turn has ended, then
// ask for the read-back. Everything about L2 (config, recognition, wording)
// comes from the SkillSet's ../hooks/probe.rb; this file holds no L2 rule.

type Entry = { name: string; session: string; written_at: string }

type Probe = {
  ok: true
  session: string
  compact_at_tokens: number
  request_ratio: number
  request_point: number
  handoff: Entry | null
  fresh: boolean
  request_text: string
  compact_instructions: string
  readback_text: string
}

// armed: waiting for the threshold; requested / compacting: a driven cycle;
// disarmed: waiting for usage below the threshold; paused: the operator
// interrupted a cycle, waiting a few turns; outside: someone else's compaction runs.
type Phase = 'armed' | 'requested' | 'compacting' | 'disarmed' | 'paused' | 'outside'

// The request and one repeat (INV-11).
const MAX_REQUESTS = 2
// Main-thread turn ends after a request that may pass without its turn being
// seen (a hook rewrote the marker, the prompt was never started) before the
// cycle moves on as if the request turn had ended.
const REQUEST_PATIENCE = 3
// Request turns that ended in an error or refusal that are not counted as
// answered; past this they count, so a lasting error still ends in a compaction.
const MAX_ERRORED = 2
// Main-thread turn ends the mod waits after the operator interrupted its cycle.
const PAUSE_TURNS = 3
// Held-off compactions in a row before waiting for the next turn end.
const MAX_VETOES = 2
// A compaction refused because a turn still runs is tried again this often.
const BUSY_RETRY_MS = 2000
const MAX_BUSY_RETRIES = 5
const MARK = '[compaction_handoff request'

// The cycle's state. Module-level: a reload of the mod starts it over, armed
// (design v0.4 §11). `gen` names the cycle; a step resumed after its cycle
// ended sees another value and does nothing (INV-11).
const cycle = {
  gen: 0,
  phase: 'armed' as Phase,
  marker: '',
  requestTurn: undefined as string | undefined,
  requestEnded: false,
  turnsSinceRequest: 0,
  requestedAt: '',
  requests: 0,
  // The request turn ended in an error or a refusal: the agent had no chance
  // to write, so the request is not counted and is asked again after a turn
  // that is not the mod's own.
  awaitOther: false,
  errored: 0,
  pauseTurns: 0,
  vetoes: 0,
  busyRetries: 0,
  retry: undefined as { cancel: () => void } | undefined,
  // True while the mod's own $.session.compact call is in flight, so the
  // session.compact observer leaves that cycle to compact() to close.
  inOwnCall: false,
  limits: undefined as { ratio: number; point: number } | undefined,
  chain: Promise.resolve() as Promise<void>,
}

// Claude Code shows the plugin's name in front of the line.
function status($: EngineInterface, text?: string) {
  $.ui.status(text)
}

function reason(err: unknown): string {
  return (err instanceof Error ? err.message : String(err)).slice(0, 100)
}

function endCycle(next: Phase) {
  cycle.retry?.cancel()
  cycle.gen += 1
  cycle.phase = next
  cycle.marker = ''
  cycle.requestTurn = undefined
  cycle.requestEnded = false
  cycle.turnsSinceRequest = 0
  cycle.requestedAt = ''
  cycle.requests = 0
  cycle.awaitOther = false
  cycle.errored = 0
  cycle.pauseTurns = 0
  cycle.vetoes = 0
  cycle.busyRetries = 0
  cycle.retry = undefined
}

// One step at a time, in arrival order. A step that fails shows why in the
// status line and leaves the cycle where the next main-thread turn end takes
// it up again (INV-11, INV-13).
function enqueue($: EngineInterface, work: () => Promise<void>) {
  cycle.chain = cycle.chain.then(work).catch((err: unknown) => {
    status($, `skipped, will retry after the next turn: ${reason(err)}`)
  })
}
// Work that outlives the hook that noticed it runs from a timer.
function later($: EngineInterface, ms: number, work: () => Promise<void>) {
  return $.clock.after(ms, () => enqueue($, work))
}

async function probe($: EngineInterface, since?: string): Promise<Probe> {
  const root = await $.session.root()
  const argv = ['ruby', `${$.plugin.root}/../hooks/probe.rb`, '--session', await $.session.id()]
  if (since) argv.push('--since', since)
  const run = await $.process.run(argv, { cwd: root, env: { CLAUDE_PROJECT_DIR: root }, timeoutMs: 30000 })
  let parsed: { ok?: boolean; error?: string }
  try {
    parsed = JSON.parse(run.stdout)
  } catch {
    throw new Error(`probe printed no JSON (exit ${run.exitCode})`)
  }
  if (run.exitCode !== 0 || parsed.ok !== true) throw new Error(`probe: ${parsed.error ?? `exit ${run.exitCode}`}`)
  return parsed as Probe
}

async function request($: EngineInterface) {
  const gen = cycle.gen
  if (cycle.requests === 0) cycle.requestedAt = new Date(await $.clock.now()).toISOString()
  const p = await probe($, cycle.requestedAt)
  if (cycle.gen !== gen) return
  cycle.marker = `${MARK} ${Math.random().toString(16).slice(2, 10)}]`
  cycle.requestTurn = undefined
  cycle.requestEnded = false
  cycle.turnsSinceRequest = 0
  cycle.requests += 1
  cycle.phase = 'requested'
  status($, `handoff requested (${cycle.requests}/${MAX_REQUESTS})`)
  // A request that never becomes a turn counts as one that ended without a
  // handoff; the next turn end moves the cycle on.
  const marker = cycle.marker
  const missed = (why: string) => {
    if (cycle.gen !== gen || cycle.marker !== marker) return
    cycle.requestEnded = true
    status($, `request not delivered (${why}); will move on after the next turn`)
  }
  void $.prompt.submit({ text: `${cycle.marker}\n${p.request_text}` }).then(
    r => {
      if ('drop' in r && r.drop !== undefined) missed(`dropped by a hook: ${r.drop}`)
    },
    (err: unknown) => missed(reason(err)),
  )
}

// After the request turn (or the patience) has passed: compact when a fresh
// handoff exists or the repeat is spent, else ask once more.
async function advance($: EngineInterface) {
  const gen = cycle.gen
  const p = await probe($, cycle.requestedAt)
  if (cycle.gen !== gen || cycle.phase !== 'requested') return
  if (p.fresh || cycle.requests >= MAX_REQUESTS) {
    cycle.phase = 'compacting'
    await compact($, p)
  } else {
    await request($)
  }
}

function retryCompact($: EngineInterface, ms: number) {
  cycle.retry?.cancel()
  cycle.retry = later($, ms, () => compact($))
}

// `known` is a probe the caller has just made in this cycle; without it the
// probe is read again (a retry, a later turn end).
async function compact($: EngineInterface, known?: Probe) {
  const gen = cycle.gen
  if (cycle.phase !== 'compacting') return
  const p = known ?? (await probe($, cycle.requestedAt))
  if (cycle.gen !== gen || cycle.phase !== 'compacting') return
  let result: Awaited<ReturnType<EngineInterface['session']['compact']>>
  cycle.inOwnCall = true
  try {
    result = await $.session.compact({ instructions: p.compact_instructions })
  } catch (err) {
    // Most often a turn still runs (INV-11): try again shortly, then at the next turn end.
    if (cycle.gen !== gen) return
    if (cycle.busyRetries < MAX_BUSY_RETRIES) {
      cycle.busyRetries += 1
      retryCompact($, BUSY_RETRY_MS)
      status($, `compaction not started (${reason(err)}); retrying`)
    } else {
      status($, `compaction not started (${reason(err)}); trying again after the next turn`)
    }
    return
  } finally {
    cycle.inOwnCall = false
  }
  if (cycle.gen !== gen) return
  if (result.skip !== undefined) {
    cycle.vetoes += 1
    if (cycle.vetoes < MAX_VETOES) {
      retryCompact($, 0)
      status($, `compaction held off (${result.skip}); trying once more`)
    } else {
      status($, `compaction held off ${cycle.vetoes} times (${result.skip}); trying again after the next turn`)
    }
    return
  }
  // Re-armed only by a measurement below the threshold (INV-10).
  endCycle('disarmed')
  status($, p.fresh ? `compacted; read back ${p.handoff?.name}` : 'compacted; no handoff was found')
  void $.prompt.submit({ text: p.readback_text }).then(
    r => {
      if ('drop' in r && r.drop !== undefined) status($, `read-back not delivered (dropped by a hook: ${r.drop})`)
    },
    (err: unknown) => status($, `read-back not delivered (${reason(err)})`),
  )
}

export const register: Register = on => {
  on('session.measure', ($, e, next) => {
    const { tokens, window } = e.context
    if (tokens !== undefined && e.changed.includes('context')) {
      // A figure belongs to the cycle it was measured in (INV-7, INV-11).
      const gen = cycle.gen
      later($, 0, async () => {
        if (cycle.gen !== gen) return
        if (!cycle.limits) {
          const p = await probe($)
          if (cycle.gen !== gen) return
          cycle.limits = { ratio: p.request_ratio, point: p.request_point }
        }
        const share = window > 0 ? Math.floor(cycle.limits.ratio * window) : cycle.limits.point
        const threshold = Math.min(cycle.limits.point, share)
        if (cycle.phase === 'disarmed' && tokens < threshold) {
          cycle.phase = 'armed'
          cycle.limits = undefined // the config is read again for the next cycle
          status($, undefined)
        } else if (cycle.phase === 'disarmed') {
          status($, `off until usage falls below ${threshold} tokens (now ${tokens})`)
        } else if (cycle.phase === 'armed' && tokens >= threshold) {
          await request($)
        }
      })
    }
    return next(e)
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined && cycle.phase === 'requested' && cycle.marker !== '' && e.text.includes(cycle.marker)) {
      cycle.requestTurn = e.turnId
    }
    return next(e)
  })

  // Every main-thread turn end takes up whatever the cycle left unfinished.
  on('turn.complete', ($, e, next) => {
    if (e.agentId === undefined) {
      const { turnId, reason: ended } = e
      later($, 0, async () => {
        if (cycle.phase === 'requested') {
          if (turnId === cycle.requestTurn) {
            if (ended === 'aborted') {
              // The operator interrupted the request turn: this cycle is theirs;
              // the mod asks again only after a few more turns (INV-13).
              endCycle('paused')
              cycle.pauseTurns = PAUSE_TURNS
              status($, `cycle cancelled: the request turn was interrupted; asking again after ${PAUSE_TURNS} turns`)
              return
            }
            if ((ended === 'error' || ended === 'refusal') && cycle.errored < MAX_ERRORED) {
              cycle.errored += 1
              cycle.requests -= 1
              cycle.awaitOther = true
              status($, `request turn ended with ${ended}; asking again after the next turn`)
              return
            }
            cycle.requestEnded = true
          } else {
            cycle.turnsSinceRequest += 1
            if (cycle.awaitOther) {
              cycle.awaitOther = false
              cycle.requestEnded = true
            }
          }
          if (cycle.requestEnded || cycle.turnsSinceRequest >= REQUEST_PATIENCE) await advance($)
        } else if (cycle.phase === 'paused') {
          cycle.pauseTurns -= 1
          if (cycle.pauseTurns <= 0) {
            cycle.phase = 'armed'
            status($, undefined)
          }
        } else if (cycle.phase === 'compacting') {
          // An interrupted turn leaves the next move to the operator: no retry
          // already scheduled may compact behind it.
          if (ended === 'aborted') {
            cycle.retry?.cancel()
            cycle.retry = undefined
            cycle.busyRetries = 0
            return
          }
          cycle.busyRetries = 0
          cycle.vetoes = 0
          cycle.retry?.cancel()
          cycle.retry = undefined
          await compact($)
        }
      })
    }
    return next(e)
  })

  // A /clear or a resume ends the conversation the cycle belongs to; the next
  // one starts armed, its config read again (INV-7: sessions do not cross).
  on('session.end', ($, e, next) => {
    endCycle('armed')
    cycle.limits = undefined
    status($, undefined)
    return next(e)
  })

  // A compaction the mod did not start ends its cycle without a read-back of
  // its own; the v0.3 SessionStart notice covers that case (INV-12).
  // The cycle ends when that compaction starts, so a step already under way
  // stops before it acts; whether it stood decides how the mod waits after it.
  on('session.compact', async ($, e, next) => {
    const foreign = !cycle.inOwnCall && e.agentId === undefined && e.trigger !== 'precompute'
    if (foreign) endCycle('outside')
    const result = await next(e)
    if (foreign && cycle.phase === 'outside') {
      endCycle(result.skip === undefined ? 'disarmed' : 'armed')
      status($, undefined)
    }
    return result
  })
}
