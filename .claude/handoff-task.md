## Current task

Execute the approved full integration of the bats + pytest test conversion — wire the `justfile`, add `pyproject.toml` + `uv.lock`, move pytest's `pythonpath` into pyproject (dropping the conftest `sys.path` hack), apply the rename-test env-prefix fix and all reviewer quality cleanups, then run the whole suite green; the ordered step-by-step checklist is in the `project-test-suite-framework-port` memory.

## Open decisions

- How `just precommit` should handle uv's cache being sandbox-blocked: allowlist `~/.cache/uv` in the sandbox config, or run precommit unsandboxed. Decide before wiring precommit — pytest-under-uv (and thus the whole recipe) fails in-sandbox without it.
