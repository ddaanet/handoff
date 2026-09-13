# The vocabulary is closed at both levels (2026-09-14)

The deliverable review of the payload-union job raised M3 against two places
where the tagged union's own argument had not been carried through: the action
objects, and the payload that holds them. Both silently discarded a key they
did not recognize. The action-object half was closed in that job's fix pass —
`_reject_unknown_keys` is called on `task`'s `clear`, `todo`'s `clear`/`keep`
and `todo`'s `edit`, so an agent told `must be "clear", got "write"` that
corrects only the action and leaves its `content` behind now errs instead of
destroying the frame. The top level was left open as a residual, and this is
it:

```
{"skill": "handoff", …, "tasks": "…"}   → exit 0, key discarded
```

A *misspelled required* key already failed loudly, because `task` and `todo`
are required by key presence — `tasks` beside nothing else gets
`task: required`. What sailed through was the superfluous key: a payload
carrying `tasks` *alongside* a well-formed `task` and `todo` is accepted
whole, and whatever the agent meant by the extra key is dropped without a
word. That is the same defect the union exists to close, one level up from
where it was closed.

## The change

`validate_top_level_keys` rejects any key outside the union of what any skill
takes — `skill`, `commit`, `rename`, `task`, `todo`, `clear`, `compact`,
`continue` — naming the first offender and listing the vocabulary. It is
called from `main` immediately after `validate_skill`, so it fires ahead of
every skill-specific validator.

The check is flat rather than skill-dependent, which is the part worth
recording, because the residual as filed described the legal key set as
skill-dependent and it does not need to be. Every *known* key present under a
skill that forbids it is already rejected, by name, upstream of where a
per-skill check could run:

| key | forbidden under | rejected by |
|---|---|---|
| `commit` | autoname, restart | the two forbidden-field validators |
| `rename` | precompact, restart | `validate_rename`; restart also by its forbidden-field validator |
| `task`, `todo` | autoname, restart | the two forbidden-field validators |
| `clear` | precompact | `_build_precompact_transition`; autoname/restart by their validators |
| `compact` | handoff | `_build_handoff_transition`; autoname/restart by their validators |
| `continue` | autoname | `validate_autoname_forbidden_fields` |

So a per-skill key set would close no gap those five do not already close. It
would do worse than nothing: there is no later point to hook it that is not
inside one of those functions, so it would run first and win, replacing
`forbidden when skill is "autoname"` and the transition-aware messages with a
generic `unknown key`. The precision it appears to add has no case left to
apply to, and the wording it would cost is the wording that tells an agent
which of its two mistakes it made. What none of the five is positioned to
catch is a key outside the vocabulary altogether, colliding with no skill's
rules and so having nothing skill-specific to say about it — and that is
exactly the flat check's subject.

The eight-key tuple is written out rather than derived from the validators'
own lists. Those lists are phrased as exclusions, four of them per-skill, and
unioning their complements would define the same vocabulary a second time,
implicitly, as an artifact of five unrelated checks. The literal names the
invariant.

## Where it runs

Immediately after `validate_skill`, which is before anything is applied. A
payload rejected here leaves the disk as it was — which is the guarantee
[Nothing is written until both halves resolve](2026-09-13-nothing-is-written-until-both-halves-resolve.md)
established for the two halves, holding here for free because the check
precedes them. The handoff row pins it: the payload's task half is `clear`
over a pre-existing frame, so moving the call below the two halves removes
that frame and reds the row. Verified by mutation, not observed passing.

Four rows, one per skill, each asserting the offending key is named rather
than merely that the exit is non-zero. The superfluous key is spelled `bogus`
and not `tasks`, because `tasks` reads as a plausible intentional field and a
row asserting on it could pass on an unrelated diagnostic; the restart row
additionally rules out the generic unknown-skill message, whose own fixed
vocabulary lists all four skill names.
