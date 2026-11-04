import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

// The hooks the tests register stand for the engine and for hooks/probe.rb:
// the probe's answer is the one the Ruby side prints (its own tests hold it).

const SID = '11111111-2222-4333-8444-555555555555'
const WINDOW = 1_000_000
const HANDOFF = { name: 'compaction_handoff_11111111_202611031200', session: 'session_x', written_at: '2026-11-03T12:00:05.000Z' }

const SUMMARY = { role: 'user' as const, text: 'summary', toolUses: [] }

type World = {
  compactDelay?: (ms: number) => Promise<void>
  rejectCompact?: boolean
  failOutside?: boolean
  fresh: boolean
  veto?: string
  probeFails?: boolean
  dropNext?: boolean
  slowProbe?: (ms: number) => Promise<void>
  submits: string[]
  compacts: (string | undefined)[]
  statuses: (string | undefined)[]
  probes: (readonly string[])[]
}

function world(on: On, init: Partial<World> = {}): World {
  const w: World = { fresh: false, submits: [], compacts: [], statuses: [], probes: [], ...init }
  on('session.id', () => ({ value: SID }))
  on('session.root', () => ({ value: '/project' }))
  on('process.run', async (_, e) => {
    w.probes.push(e.argv)
    if (w.slowProbe) await w.slowProbe(1000)
    const body = w.probeFails
      ? { ok: false, error: 'config has no compaction_handoff section' }
      : {
          ok: true,
          session: SID,
          compact_at_tokens: 1_000_000,
          request_ratio: 0.7,
          request_point: 700_000,
          handoff: w.fresh ? HANDOFF : null,
          fresh: w.fresh,
          request_text: 'REQUEST',
          compact_instructions: w.fresh ? `KEEP ${HANDOFF.name}` : 'NO HANDOFF',
          readback_text: w.fresh ? `READ ${HANDOFF.name}` : 'NONE FOUND',
        }
    const stdout = JSON.stringify(body)
    return { value: { exitCode: w.probeFails ? 1 : 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('prompt.submit', (_, e) => {
    w.submits.push(e.text)
    if (w.dropNext) {
      w.dropNext = false
      return { drop: 'refused by a guard' }
    }
    return { text: e.text }
  })
  on('session.compact', async (_, e) => {
    w.compacts.push(e.instructions)
    if (w.rejectCompact) throw new Error('a turn is running')
    if (w.failOutside && e.instructions === 'the person typed /compact') throw new Error('summary failed')
    if (w.compactDelay) await w.compactDelay(2000)
    return w.veto === undefined ? { messages: [SUMMARY] } : { skip: w.veto }
  })
  on('ui.status', (_, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  return w
}

async function measure($: Engine, tokens: number) {
  await $.session.measure({
    context: { tokens, window: WINDOW, percent: Math.round((tokens * 100) / WINDOW) },
    rateLimits: [],
    changed: ['context'],
  })
}

async function turn($: Engine, turnId: string, text: string, reason: 'answer' | 'aborted' = 'answer') {
  await $.turn.start({ text, turnId })
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: reason === 'aborted', turnId, reason })
}

const lastSubmit = (w: World) => w.submits.at(-1) ?? ''

test('below the threshold nothing is asked', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 699_999)
  await clock.settle()
  expect(w.submits).toEqual([])
  expect(w.compacts).toEqual([])
})

test('past the threshold: ask, compact right after the request turn, then read back', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 700_000)
  await clock.settle()
  expect(w.submits.length).toBe(1)
  expect(lastSubmit(w).startsWith('[compaction_handoff request ')).toBe(true)
  expect(lastSubmit(w)).toContain('REQUEST')
  expect(w.probes.at(-1)?.includes('--since')).toBe(true)

  // A turn the mod did not start (a peer arrival) does not compact.
  await turn($, 'other', 'a peer message arrived')
  await clock.settle()
  expect(w.compacts).toEqual([])

  w.fresh = true
  await turn($, 'req', lastSubmit(w))
  await clock.settle()
  expect(w.compacts).toEqual([`KEEP ${HANDOFF.name}`])
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)

  // A stale figure after the compaction does not start a second cycle;
  // a figure below the threshold re-arms the mod.
  for (const stale of [800_000, 800_000]) {
    await measure($, stale)
    await clock.settle()
  }
  expect(w.submits.length).toBe(2)
  expect(w.statuses.at(-1)).toBe('off until usage falls below 700000 tokens (now 800000)')
  await measure($, 90_000)
  await clock.settle()
  await measure($, 750_000)
  await clock.settle()
  expect(w.submits.length).toBe(3)
  expect(lastSubmit(w)).toContain('REQUEST')
})

test('without a handoff: one repeat request, then compaction anyway', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  const first = lastSubmit(w)
  await turn($, 'r1', first)
  await clock.settle()
  expect(w.compacts).toEqual([])
  expect(w.submits.length).toBe(2)
  const second = lastSubmit(w)
  expect(second.split('\n')[0]).not.toBe(first.split('\n')[0])
  // The first request's turn cannot be taken for the repeat's.
  await turn($, 'r1-again', first)
  await clock.settle()
  expect(w.compacts).toEqual([])
  await turn($, 'r2', second)
  await clock.settle()
  expect(w.compacts).toEqual(['NO HANDOFF'])
  expect(lastSubmit(w)).toBe('NONE FOUND')
})

test('an interrupted request turn cancels the cycle', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true })
  await measure($, 720_000)
  await clock.settle()
  await turn($, 'r1', lastSubmit(w), 'aborted')
  await clock.settle()
  expect(w.compacts).toEqual([])
  expect(w.submits.length).toBe(1)
  expect(w.statuses.at(-1)).toContain('interrupted')
})

test('a held-off compaction is tried once more, then again after the next turn', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true, veto: 'blocked by a hook' })
  await measure($, 720_000)
  await clock.settle()
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  expect(w.compacts.length).toBe(2)
  expect(w.submits.length).toBe(1)
  expect(w.statuses.at(-1)).toContain('trying again after the next turn')
  // The next turn end starts a fresh pair of tries.
  await turn($, 'peer', 'a peer message arrived')
  await clock.settle()
  expect(w.compacts.length).toBe(4)
  w.veto = undefined
  await turn($, 'peer2', 'another peer message')
  await clock.settle()
  expect(w.compacts.length).toBe(5)
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)
})

test('a probe failing when the request turn ends is taken up at the next turn end', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  w.probeFails = true
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  expect(w.compacts).toEqual([])
  expect(w.statuses.at(-1)).toContain('will retry after the next turn')
  w.probeFails = false
  w.fresh = true
  await turn($, 'peer', 'a peer message arrived')
  await clock.settle()
  expect(w.compacts).toEqual([`KEEP ${HANDOFF.name}`])
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)
})

test('a step still waiting on its probe does nothing once an outside compaction ended the cycle', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  w.fresh = true
  w.slowProbe = ms => clock.sleep(ms)
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  await $.session.compact({ trigger: 'manual', instructions: 'the person typed /compact', messages: [SUMMARY] })
  // Long enough for any continuation of the ended cycle to run all its probes.
  for (let i = 0; i < 5; i++) await clock.advance(1000)
  await clock.settle()
  expect(w.compacts).toEqual(['the person typed /compact'])
  expect(w.submits.length).toBe(1)
})

test('a request a hook drops, or whose turn is never seen, is moved on', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { dropNext: true })
  await measure($, 720_000)
  await clock.settle()
  expect(w.statuses.at(-1)).toContain('request not delivered')
  await turn($, 'peer', 'a peer message arrived')
  await clock.settle()
  expect(w.submits.length).toBe(2)
  // The repeat's turn is never seen (its marker did not survive): after the
  // patience the cycle compacts without a handoff.
  for (const id of ['p1', 'p2', 'p3']) await turn($, id, 'unrelated')
  await clock.settle()
  expect(w.compacts).toEqual(['NO HANDOFF'])
  expect(lastSubmit(w)).toBe('NONE FOUND')
})

test('a compaction the mod did not start ends its cycle without a read-back', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true })
  await measure($, 720_000)
  await clock.settle()
  await $.session.compact({ trigger: 'manual', instructions: 'the person typed /compact', messages: [SUMMARY] })
  await clock.settle()
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  expect(w.compacts).toEqual(['the person typed /compact'])
  expect(w.submits.length).toBe(1)
})

test('a failing probe asks nothing and says why', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { probeFails: true })
  await measure($, 900_000)
  await clock.settle()
  expect(w.submits).toEqual([])
  expect(w.statuses.at(-1)).toContain('config has no compaction_handoff section')
})

test('a model with a smaller window is asked at its own share', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await $.session.measure({ context: { tokens: 140_000, window: 200_000, percent: 70 }, rateLimits: [], changed: ['context'] })
  await clock.settle()
  expect(w.submits.length).toBe(1)
})

test('a /clear ends the cycle: nothing of it reaches the next conversation', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true })
  await measure($, 720_000)
  await clock.settle()
  const request = lastSubmit(w)
  await $.session.end({ reason: 'clear', sessionId: SID, resume: { id: SID } })
  await clock.settle()
  for (const id of ['n1', 'n2', 'n3', 'n4']) await turn($, id, id === 'n1' ? request : 'new conversation')
  await clock.settle()
  expect(w.compacts).toEqual([])
  expect(w.submits.length).toBe(1)
  // The new conversation starts armed.
  await measure($, 720_000)
  await clock.settle()
  expect(w.submits.length).toBe(2)
})

test('a request turn that ends in an error is asked again, not counted', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  await $.turn.start({ text: lastSubmit(w), turnId: 'r1' })
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 'r1', reason: 'error' })
  await clock.settle()
  expect(w.submits.length).toBe(1)
  expect(w.statuses.at(-1)).toContain('ended with error')
  await turn($, 'peer', 'a peer message arrived')
  await clock.settle()
  expect(w.submits.length).toBe(2)
  // The errored request did not use up the repeat: one more unanswered
  // request turn still asks again rather than compacting.
  await turn($, 'r2', lastSubmit(w))
  await clock.settle()
  expect(w.compacts).toEqual([])
  expect(w.submits.length).toBe(3)
})

test('an outside compaction ends the cycle when it starts, not when it finishes', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  w.slowProbe = ms => clock.sleep(ms / 2)
  w.compactDelay = ms => clock.sleep(ms)
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  const outside = $.session.compact({ trigger: 'manual', instructions: 'the person typed /compact', messages: [SUMMARY] })
  for (let i = 0; i < 6; i++) await clock.advance(500)
  await outside
  await clock.settle()
  expect(w.compacts).toEqual(['the person typed /compact'])
  expect(w.submits.length).toBe(1)
})

test('while waiting to compact, a turn the operator interrupted is left alone', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true, veto: 'blocked by a hook' })
  await measure($, 720_000)
  await clock.settle()
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  expect(w.compacts.length).toBe(2)
  w.veto = undefined
  await turn($, 'peer', 'a peer message arrived', 'aborted')
  await clock.settle()
  expect(w.compacts.length).toBe(2)
  await turn($, 'next', 'the operator typed something')
  await clock.settle()
  expect(w.compacts.length).toBe(3)
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)
})

test('a measurement taken before a /clear does nothing after it', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.slowProbe = ms => clock.sleep(ms)
  await measure($, 720_000)
  await clock.settle()
  await $.session.end({ reason: 'clear', sessionId: SID, resume: { id: SID } })
  for (let i = 0; i < 4; i++) await clock.advance(1000)
  await clock.settle()
  expect(w.submits).toEqual([])
})

test('an interrupt while a refused compaction waits to retry cancels that retry', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true })
  await measure($, 720_000)
  await clock.settle()
  w.rejectCompact = true
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  const tried = w.compacts.length
  expect(tried).toBeGreaterThan(0)
  await turn($, 'peer', 'the operator stopped this turn', 'aborted')
  await clock.settle()
  w.rejectCompact = false
  for (let i = 0; i < 6; i++) await clock.advance(2000)
  await clock.settle()
  expect(w.compacts.length).toBe(tried)
  await turn($, 'next', 'the operator typed something')
  await clock.settle()
  expect(w.compacts.length).toBe(tried + 1)
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)
})

test('request turns that keep ending in an error still end in a compaction, after a bounded number', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  for (let i = 0; i < 8 && w.compacts.length === 0; i++) {
    await $.turn.start({ text: lastSubmit(w), turnId: `r${i}` })
    await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: `r${i}`, reason: 'error' })
    await clock.settle()
    await turn($, `peer${i}`, 'a peer message arrived')
    await clock.settle()
  }
  expect(w.compacts).toEqual(['NO HANDOFF'])
  expect(w.submits.filter(t => t.startsWith('[compaction_handoff request')).length).toBeLessThanOrEqual(4)
})

test('after an interrupted request the mod waits a few turns before asking again', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 720_000)
  await clock.settle()
  await turn($, 'r1', lastSubmit(w), 'aborted')
  await clock.settle()
  await measure($, 730_000)
  await clock.settle()
  expect(w.submits.length).toBe(1)
  for (const id of ['a', 'b', 'c']) await turn($, id, 'operator work')
  await clock.settle()
  await measure($, 740_000)
  await clock.settle()
  expect(w.submits.length).toBe(2)
})

test('no cycle starts while someone else is compacting', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await measure($, 100_000)
  await clock.settle()
  w.compactDelay = ms => clock.sleep(ms)
  const outside = $.session.compact({ trigger: 'manual', instructions: 'the person typed /compact', messages: [SUMMARY] })
  await clock.settle()
  await measure($, 900_000)
  await clock.settle()
  expect(w.submits).toEqual([])
  for (let i = 0; i < 3; i++) await clock.advance(1000)
  await outside
  await clock.settle()
  await measure($, 900_000)
  await clock.settle()
  expect(w.submits).toEqual([])
  expect(w.statuses.at(-1)).toContain('off until')
})

test('an outside compaction that fails leaves the mod armed, not stuck', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { failOutside: true })
  await measure($, 100_000)
  await clock.settle()
  try {
    await $.session.compact({ trigger: 'manual', instructions: 'the person typed /compact', messages: [SUMMARY] })
  } catch {
    // the engine reports the failure to the operator
  }
  await clock.settle()
  await measure($, 900_000)
  await clock.settle()
  expect(w.submits.length).toBe(1)
})

test('an interrupt holds off a retry that is already probing', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on, { fresh: true })
  await measure($, 720_000)
  await clock.settle()
  w.rejectCompact = true
  await turn($, 'r1', lastSubmit(w))
  await clock.settle()
  const tried = w.compacts.length
  w.rejectCompact = false
  w.slowProbe = ms => clock.sleep(ms)
  // The 2 s retry fires and starts probing; the operator interrupts meanwhile.
  await clock.advance(2000)
  await clock.settle()
  await turn($, 'peer', 'the operator stopped this turn', 'aborted')
  for (let i = 0; i < 4; i++) await clock.advance(1000)
  await clock.settle()
  expect(w.compacts.length).toBe(tried)
  await turn($, 'next', 'the operator typed something')
  for (let i = 0; i < 4; i++) await clock.advance(1000)
  await clock.settle()
  expect(w.compacts.length).toBe(tried + 1)
  expect(lastSubmit(w)).toBe(`READ ${HANDOFF.name}`)
})
