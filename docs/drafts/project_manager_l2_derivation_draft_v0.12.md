# project_manager — deriving activity evidence from L2 — v0.12 FROZEN

**Status:** **FROZEN 2026-07-27** by the operator, on the basis that the deployment-grounded and philosophy-aligned findings are exhausted rather than that the roster's numeric threshold was met — the same basis v0.7 was frozen on. Round five returned zero deployment-grounded findings for the first time in five rounds, and three reviewers who ran the deployment independently reported that every mechanism claim in it survives being checked. The remaining findings were textual and are applied. Narrower than its predecessors. Four rounds established that this document was carrying two designs with different convergence: deriving evidence from L2, whose every measured claim has reproduced under independent reviewers for three consecutive rounds, and getting that evidence into the memo and thence to the secretary, which produced a fresh deployment-grounded defect in each of those rounds. **The second is removed here and handed to a separate design.** §8 says why, and why it belongs to a successor of v0.7 rather than here.
**Date:** 2026-07-27
**Author:** orchestrator (Opus 5), from operator decisions taken in session.
**Relation to v0.7:** Extends rather than supersedes, and no longer reaches into it. v0.7 governs *who* the secretary is, *what it may reach*, and what it reports; every invariant it froze still holds. This governs one thing: how evidence of activity is read out of the context store. They meet in §7.
**Purpose:** Give the operator, from KairosChain's own record, a per-item view of what has recently been written near each piece of work — because the memo is maintained by remembering and the record is maintained by working.

---

## 0. What measurement established, and what it did not

The operator's decision was that the source must be KairosChain's own record and that the same fact must not be maintained in two places. That decision preceded any measurement. Measurement then established that it was corrective and not merely tidier, and separately established that the author was the least reliable component in the exercise.

**The memo is behind, and the size of the gap depends on how wide the derivation looks.** Reading names, paths and tags, fifteen of the twenty-one items with any nearby record had L2 activity more recent than the memo's last touch, with a median gap of eighteen days and a widest of sixty-five. Reading names and paths but not tags — the conservative bound, since a tag is one route by which a neighbouring subject enters — fourteen items, median sixteen, widest forty-three. **The pair is the result. A single figure would be asserting the attribution §6 declines to claim.** It describes a standing condition rather than a defect this design repairs — nothing here writes to the memo, so no delta here will ever close; what changes is that the drift becomes visible. Twenty-two items exist; the twenty-second has no nearby record at all and is §3's subject. Underneath both readings sits one case needing no arithmetic: the secretary's one real report described a piece of work as *design v0.5 frozen, three tasks remaining* while the context store held, from the same morning, *shipped, v0.7 frozen, gem published and installed*.

**The direction of the gap is not the direction of staleness.** The single item whose memo entry looked more recent is a rejection the operator entered by hand three weeks after L2 recorded it in a debrief written the week it happened. The arithmetic said the memo was ahead; the fact was three weeks stale in it.

**The author's errors, and what four rounds of them showed.** Across four rounds this design asserted eleven things about the deployment that were false, every one of them in a document whose §0 confessed that exact habit. They fall into two kinds and the split is the reason for this version's scope. Six were claims about *data* — what the store contains: that a bundled knowledge entry was retrievable, that a search index was a keyword artifact, that a provider was constructed disabled, that contexts are sometimes saved twice, that L2 is append-only, and that the widest gap had survived correction. Reviewers caught each by measuring; none has recurred, and the figures above have now reproduced independently for four consecutive rounds. Five were claims about *mechanism*: that a field did not exist, that a write path did not exist, that a marker was a report's sole input, that one additive change would surface a value, that the change was needed at all. Every one was false, each was refuted by opening a file, and **one of them was refuted by the same paragraph of v0.7 that the previous round had quoted to repair the one before it.** The pattern did not improve across rounds; it moved one layer outward each time. **Its subject was always the half of the design that reaches into v0.7's territory, and removing that half is the only change this version makes that a further round of care would not have produced.**

**What is not established.** Eighteen of the twenty-one matched items have not been individually inspected. The aggregate supports the claim that the memo lags; no individual figure is yet evidence about the item it sits beside.

---

## 1. Why derivation, and what it is for

Two records of the same work drift, and the drift is invisible from whichever one is being read. That is not an argument for merging them. It is an argument for reading one out of the other.

The asymmetry that decides which is the source is narrower than earlier versions claimed and does not need the claim they made. L2 is not append-only — contexts are deletable at the store layer, though no tool exposes deletion, and saving under a name already used within the same session rewrites it. What is true is that L2 is **written by the session doing the work, as a condition of the work being done**, while the memo is written when someone remembers. Only one is maintained by the act of working, and that is sufficient.

**Invariant.** Derivation produces a view and changes nothing. It is a reading of the record, not a stage in a pipeline that ends in the memo.

Earlier versions treated the memo as derivation's destination and repeatedly failed there — on what the memo could hold, on what a write to it disturbs, on what reaches the secretary. Those failures were not incidental: each concerned a mechanism v0.7 owns. Stating derivation as a view removes the assumption that produced them. What the operator does with the view is a decision the view does not make, and §8 records where that decision now lives.

The memo remains what it was. It holds intentions — a deadline, an intended date, a weight — which are the things L2 cannot carry, because L2 records what happened and not what was meant to happen next. Nothing here changes it.

---

## 2. What derivation may look at

**Invariant.** Derivation reads what a document declares about itself — its name, the path it was saved under, and its tags. It does not read the body.

Body matching raises recall and destroys precision: of twelve items whose result it changed, nine changed to work belonging elsewhere. A record of a mention is not a record of participation, and prose mentions everything.

The three admitted fields are not equally deliberate, and §0's two readings are exactly the comparison between them. A name and a tag are both assertions someone made, and a path carries two things at once: the name the context was saved under, which is also authored and differs from the declared name in a quarter of this store, and a session prefix, which is generated and carries only a date. The narrow reading drops the tag channel and keeps the two name channels. It reads strictly less, and what it drops is the channel by which a subject a document merely touches can pull it in — so the pair brackets the effect of that channel.

The invariant binds derivation, not presentation. Deriving means asserting, and an assertion must be answerable for why it was made; a similarity score is not an answer a reader can check. Offering a record as *nearby* asserts nothing, so it is bound by usefulness instead. Any richer reading of the body belongs on that side of the line, and §8 records what exists today.

**Invariant.** A record's identity is its whole content, body included. Two files of identical content are one record; two files sharing a name but not content are two, because both were written.

Identity and matching read different things on purpose. Nothing is *matched* on the body; a record is *identified* by all of it, because two files that differ only in a paragraph are two things that happened.

This store contains no byte-identical pair, and twenty-five declared names carry revision series — thirty-one if counted by the name each was saved under, which is the same distinction the paragraph above turns on and is why the reading is stated. Collapsing by name would therefore discard records and collapse nothing.

**Invariant.** Derivation is deterministic. The same store yields the same view — including where several records share a date, and where one record is present as two files whose paths are all that distinguish them.

Both halves were defects before they were an invariant: an ordering that ties broke arbitrarily, and a deduplication that let the filesystem choose which of a record's files supplied its path and dates. Neither is visible on today's data, which is why the invariant is stated rather than left to the artifact — a determinism that holds only because the store has not yet contained the awkward case is not a property, it is luck.

**Invariant.** A document declaring no date is counted and reported, not dropped; and no aggregate figure carries a matched record's status.

Dropping the undated reported an invisible record as absent work; seven contexts are in that state today. The status prohibition is scoped to aggregates deliberately — a per-record view showing each record's own status beside its own name asserts nothing about an item, and §7 bounds what may be carried out of that view.

---

## 3. Where a gap is repaired

An item can fail to have evidence in two ways, and they are not the same failure. Nobody has said which records to look at; or someone has, and L2 carries no matching label. The first is a gap in the mapping, the second a gap in the record, and derivation names which it is.

**Invariant.** A missing label is repaired in L2, by labelling the work. Derivation is not widened to reach it.

This inverts the usual instinct, which is to make the tool cleverer. A cleverer tool accumulates exceptions no later reader can audit; a labelled record is auditable by reading it. The instinct will recur, because every future gap presents as a deficiency of the scan.

The invariant and §4's authorship look like they could contradict — adding a term is both authoring a mapping and widening a reach — and the test that separates them is whether the added term names *the work* or names *where the work happens to be discussed*. A term that would be a reasonable tag on the item's own records is authorship. A term chosen because it happens to appear near them is widening. That test is applied by a human and nothing enforces it; it is stated so the person it binds can apply it, not because the design can check it.

What derivation reports is the count of items with **no nearby record at all** — one today. That is not the count of work L2 has failed to label, and the difference matters: an item whose own work carries no label but whose terms brush a neighbour's records has evidence beside it and never raises the flag. Counting the true backlog would require deciding which records are an item's own, which is what §6 declines, so the reported number is a floor of unknown tightness and is stated as one.

---

## 4. The mapping, and the one thing a human owns

Every item needs to know which records to look at. Nothing in either store says so, and nothing can infer it: the memo's titles are the operator's shorthand and L2's names are the session's.

**Invariant.** The correspondence between an item and the records to look at is authored, not inferred, and it is the only input to derivation a human supplies.

Most of it was already written. Sixteen of twenty-two items carry a note; fourteen of those notes point at a context by name, and twelve of those names resolve to a context that exists — the other two point at operator memory files under the same notation. Placed there by hand, over months, for human use. Its existence is evidence that the correspondence is something the operator records naturally rather than an obligation this design invents, and the two that do not resolve are evidence that a hand-written pointer is not a substitute for a checked one.

**Invariant.** The authored correspondence can express a distinction the names cannot make on their own.

Names in this project nest: one artifact's name is a prefix of another's, and the shorter matches both. A correspondence that can only say *look for this* cannot say *this subject and not that one*, so it would be unable to state a distinction the record actually makes — not merely less precise.

---

## 5. What the derived figures mean, and what they do not

Derivation yields, per item, when activity near it first and last appears, how many distinct records exist, and on how many distinct days those records were written.

Distinct days is preferred to record count wherever one must be chosen. A record is written each time a review round-trips, so the count measures how contested a piece of work was rather than how much of it there was.

**Invariant.** A derived figure is named for what it measures, and no figure is offered as an item's status.

Every figure here has already misled its author within a day of being computed. The interval between the memo's last touch and L2's last activity measures *when each side was last written to*; the rejection case in §0 is a fact stale in the memo while the arithmetic said the reverse. Days ranged from one to eighteen with a median of four, which invites an estimate and cannot support one, because items are not comparable units. And an early artifact printed the status of whichever nearby record sorted last as though it were the item's own — reproducing, as a fix, precisely the failure §0 opens with. What may be shown is the nearby record itself, named, so the operator can see what they are being shown.

The interval against the memo's marker is the fifth thing the view shows, and it is shown for the same reason §0 uses it: it is how drift becomes visible at all. It is named last because it is the figure that misled hardest. Presentation orders by it, and ties fall back to the memo's own item order, which is stable for a fixed store — deterministic, but inherited rather than chosen.

That is the whole of what derivation asserts. It does not say what should be done about a gap it reports, and it does not put anything anywhere.

---

## 6. Attribution is not claimed

A tag says what a document is *about*. An item says what remains to be *done*. These are different granularities, and one document sits correctly under several items.

This is not a labelling error to be cleaned up. The clearest instance is a set of records about one projection mechanism that legitimately carry another projector's tag, because the work touched both — and it is the record that produces §0's widest gap under the wide reading and not under the narrow one.

**Invariant.** Derivation does not assert which item a record belongs to. It reports what has been written near an item, names the records, and the operator judges.

The alternatives were weighed and declined. Coarsening items until they match subjects restores attribution and costs the secretary its subject matter — an item at subject granularity contains no next step, and proposing one is the disposition's whole value. Requiring future records to declare their item is exact but reaches nothing already written; it would need a reader before it converged, and both the writing and the reading are outside this design.

What this costs is the ability to state a single number where §0 states a pair, and the ability to count §3's backlog rather than bound it. What it buys is that five months of existing records are usable today. The claim surrendered is one the record cannot support, and a design that kept it would be asserting an attribution the data does not carry.

---

## 7. Where this meets v0.7

**Invariant.** Derivation reads three things — the context store, the memo's list of items, and the authored correspondence — and writes nothing, anywhere. It is invoked by the operator and its output goes to the operator.

Naming all three matters: an earlier draft said only *the context store*, which understated the reach of a component that also reads every item title in the memo. Writing nothing is a property checkable by reading the component, which is what four rounds of the previous scope could not achieve for anything in this region. It does not by itself discharge v0.7's concern, which is about a *read* surface: v0.7 established that a narrow tool list is not a narrow surface, because a granted read returns items whole into a transcript the harness retains. That concern is discharged instead by the next invariant and by this design granting the secretary nothing new.

**Invariant.** What may be carried out of the view and into the memo is what a record is called, when it was written, and figures computed from those. A record's own status may be read in the view and may not be copied out of it.

This is a discipline on the operator's act, not a property of the component, and it is stated here because the act has no design of its own today. Its ground is v0.7's frozen requirement that the memo hold nothing which may not outlive the moment it is read. A record's name and dates are unremarkable in a retained transcript; a status line lifted whole is a claim about work this design refuses to attribute, arriving somewhere it can be read back whole. The per-record view does show each record's own status — that is what makes the limit necessary rather than decorative.

The secretary is untouched. It reads the memo through the tools v0.7 granted it, it does not read L2, and nothing here proposes it should — granting it the context store would hand it a surface several hundred times larger than the one that produced a credential exposure during v0.7's own review.

**A retraction.** An earlier version of this document stated that v0.7's backlog entry about unreachable SkillSet-bundled knowledge was settled. That statement was made without checking and is withdrawn. The mechanism was changed and a bundled entry does resolve, but the change's own review returned no approvals and three demonstrated defects with the fix unapplied, so whether it is settled is exactly what is open. The frozen backlog entry stands as written until that closes.

---

## 8. What was removed, the backlog, and what is out of scope

**The half that was removed.** Its receiver is a successor to v0.7 — v0.7 itself is frozen and can receive nothing — and this paragraph is currently that successor's only record, in an untracked draft, which is the durability problem v0.7 records about itself. Getting derived evidence into the memo, keeping the copy from disturbing the marker the neglect report depends on, and surfacing an uncopied memo to the operator — all of it is out of scope here and belongs with v0.7. Three reasons, and the third is the one that decided it. Every mechanism it needs is v0.7's: the memo's fields, the write path's mechanical flag, the digest's shape, and the secretary's disposition, which prescribes the report's content exhaustively so that a value the disposition does not name is not reported however it is stored. The v0.7 backlog has already reserved the field the last attempt used, for an incompatible forward-looking purpose, which is a collision only a v0.7 revision can resolve. And four rounds produced a fresh mechanism error in that half every time while producing none in this half, which is the empirical form of the same observation: **this design was reaching across a boundary, and reaching is what it kept getting wrong.**

What that half should know when it is written: the data is already in the secretary's hands — the query tool returns items whole, and the disposition already fills one digest gap by that route — so the work is a disposition change rather than a code change; the mechanical flag exists and composes with a field write exactly as needed, but defaults to the unsafe value, so a rule that depends on the operator remembering it is fail-open; when the flag is forgotten the marker and the written field take the same date, which is a free detector nothing currently uses; and the digest carries per-item lines only for items already in a bucket, so an unbucketed item cannot be surfaced by adding a field to those lines however the field is stored.

**Verification owed.** Eighteen of twenty-one matched items have not been inspected. Under §6 an inspection cannot establish that a record belongs to an item; what it can establish is whether the records shown beside an item are ones an operator would want to see, which is the acceptance criterion.

**Presentation by similarity.** §2 places any richer reading of the body on the presentation side. A vector-search component exists, indexing definitions and knowledge entries; the context store is not among its sources. Its on-disk index is an embedding artifact and the knowledge provider's default is enabled — it is inert because the two libraries the semantic path requires are absent, which is a different condition with different consequences if they are ever installed. Extending it to contexts is a plausible route to §6's *nearby* face and a poor one to §5's figures, since a similarity score cannot answer for itself.

**Reach.** The chain records changes to definitions and is a second dated source about the same work, unread here. Whether it adds anything the context store lacks is untested.

**Scope of the store.** The instance's records include work belonging to projects that are not this gem, and the operator's decision is that they stay. Derivation therefore runs across everything present and separates by project at the item, not by filtering the record. Should instances later be separated per project the records would need dividing, and nothing here prepares for that — deliberately, since preparing for a division that may not happen is the pre-designed robustness this project declines.

**Out of scope.** No change to the secretary's grant, its disposition, or any invariant v0.7 froze. No write of any kind. No change to how contexts are saved. No promotion to the distributed package: this derives from one operator's records and belongs with them.
