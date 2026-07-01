#!/usr/bin/env bash
#
# secret-patterns.sh — shared secret/placeholder signatures, sourced by both
# githooks/pre-commit (staged-diff guard) and githooks/scan-tree.sh (whole-tree
# export backstop). Single source of truth so the two can't drift.
#
# Defines two variables: ALLOW_RE and CRED_RE (extended-regex strings).

# Lines containing any of these are obvious templates/placeholders/env-refs and
# are excused from the CREDENTIAL heuristics (NOT from an org blocklist).
ALLOW_RE='YOUR_|<[A-Za-z_]|EXAMPLE|example|placeholder|PLACEHOLDER|REDACT|redact|changeme|xxxxx|\$\{[A-Za-z_]|\$[A-Za-z_][A-Za-z0-9_]*'

# Credential signatures (single combined ERE). Built by append so it stays
# readable; consumers must pass it via `grep -E -e "$CRED_RE"` (it starts with
# '-----' which grep would otherwise read as options).
CRED_RE='-----BEGIN[A-Z ]*PRIVATE KEY[A-Z ]*-----'
CRED_RE="$CRED_RE"'|A(KIA|SIA)[0-9A-Z]{16}'
CRED_RE="$CRED_RE"'|(ghp|gho|ghs|ghr|ghu)_[A-Za-z0-9]{20,}'
CRED_RE="$CRED_RE"'|github_pat_[A-Za-z0-9_]{20,}'
CRED_RE="$CRED_RE"'|sk-(ant-)?[A-Za-z0-9_-]{20,}'
CRED_RE="$CRED_RE"'|AIza[0-9A-Za-z_-]{35}'
CRED_RE="$CRED_RE"'|xox[baprse]-[A-Za-z0-9-]{10,}'
CRED_RE="$CRED_RE"'|(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+._-]{12,}'
CRED_RE="$CRED_RE"'|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}'
CRED_RE="$CRED_RE"'|[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]:@]{8,}@'
CRED_RE="$CRED_RE"'|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
