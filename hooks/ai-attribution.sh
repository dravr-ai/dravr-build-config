#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copyright (c) 2026 dravr.ai
# ABOUTME: The one definition of AI attribution, sourced by the commit-msg and pre-push hooks
# ABOUTME: Names the message lines and the commit identities no dravr-* commit may carry

# Not a hook. Git runs only files named after a hook, so this file is inert in
# core.hooksPath and exists to be sourced. Both hooks read their rules from here,
# so a commit refused at commit time is refused at push time for the same reason,
# and a pattern added here reaches both.

# A message line that credits an AI tool, matched with `grep -iE` anywhere on the
# line: a Co-Authored-By trailer naming Claude or Anthropic, a "Generated with"
# footer, the robot emoji, the Claude-Session trailer, a claude.ai/code session
# link, and Anthropic's noreply address in any trailer.
# shellcheck disable=SC2034  # read by the hooks that source this file
AI_MESSAGE_RE='Co-Authored-By.*claude|Co-Authored-By.*anthropic|Generated with|🤖|Claude-Session:|claude\.ai/code|noreply@anthropic\.com'

# ai_identity_is_ai <name> <email>
# Succeeds when the identity belongs to an AI tool: a name that is exactly
# "Claude", or an address at anthropic.com, both case-insensitive. The reason is
# left in AI_IDENTITY_WHY rather than printed, so pre-push can judge thousands of
# commits without forking a subshell per call.
ai_identity_is_ai() {
    local name=$1 email=$2 was_set=0
    shopt -q nocasematch && was_set=1
    shopt -s nocasematch
    AI_IDENTITY_WHY=""
    if [[ $name == claude ]]; then
        AI_IDENTITY_WHY="named \"$name\""
    elif [[ $email == *@anthropic.com ]]; then
        AI_IDENTITY_WHY="address at anthropic.com"
    fi
    [ "$was_set" = 1 ] || shopt -u nocasematch
    [ -n "$AI_IDENTITY_WHY" ]
}

# How to make a commit carry a human identity, printed by both hooks.
ai_identity_fix_hint() {
    cat <<'EOF'
   A dravr-* commit is authored and committed by the human who makes it. Set yours:
     git config user.name "Your Name"
     git config user.email "you@example.com"
   An --author= flag and GIT_AUTHOR_* / GIT_COMMITTER_* environment variables override
   that config: drop or unset them. Amending keeps the old author: add --reset-author.
   Check with: git var GIT_AUTHOR_IDENT; git var GIT_COMMITTER_IDENT
EOF
}
