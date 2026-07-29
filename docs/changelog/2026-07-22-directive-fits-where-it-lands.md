# A directive must fit where in the turn it lands (2026-07-22)

The todo-file suppression shipped as one sentence composed by both probes:
*"do not write `.claude/handoff-todo.md`."* Correct for precompact, which runs
its probe at step 2 and writes at step 3. A no-op for handoff, which runs the
probe **in the same turn as the writes** — deliberately, so the snapshot costs
one round trip — and therefore always reads the directive after the file
exists. An agent following it exactly does nothing, and the session ends with
the two ledgers the suppression exists to prevent, the losing one gitignored
and re-injected next session as if it were current.

So `probe_todo_suppression` now names the cleanup — delete it if already
written — while `probe_sdd_directive` keeps the plain prohibition. The two
still agree on what exists, which is what `probe_ledger_path` is for; they
differ on the remedy, because a directive is only as good as its position in
the turn. The general form: shared prompt text composed into two flows is only
shared where the flows agree, and *when the agent reads it* is part of the
contract, not an implementation detail of the caller.

A skill that cross-references another skill's template has the same shape of
bug. precompact said to use "the template in the `handoff` skill" and stopped
there. A path existed — the harness loads a skill body with its own absolute
base directory, so `../handoff/SKILL.md` was always one Read away — but the
skill never named it, and the route that *looks* available from inside a turn
is invoking `handoff`, which is the wipe trigger, firing between precompact's
task-file write and its todo write and taking both with it. precompact now
states the section shapes inline for the common case, names the relative path
for the full rules, and forbids the invocation explicitly. Naming the safe
route is the load-bearing half: a prohibition with no alternative just moves
the guess.

Both fixes are the same lesson at two scales. Guidance is not a statement of
fact to be checked for truth; it is read at a particular moment by a reader
with particular reach, and it is correct only if it works from there.
