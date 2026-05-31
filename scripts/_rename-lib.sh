#!/usr/bin/env bash
# shellcheck shell=bash
# Pure predicates over captured tmux pane text (read stdin).
# Sourced by rename-when-idle.sh; do not execute directly.
# shellcheck disable=SC2034  # consumed by sourcing scripts

# Strip ANSI escapes and carriage returns.
strip() { sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }

# Busy while the Claude TUI chrome spinner is on screen: timer reads
# "(<n>s ·" or the "esc to interrupt" hint is visible.
is_busy() { strip | grep -Eq '\([0-9]+s ·|esc to interrupt'; }

# Typing: the last "❯" prompt line has non-space content — user is composing.
is_typing() { strip | grep -E '❯' | tail -n1 | grep -Eq '❯[[:space:]]+[^[:space:]]'; }
