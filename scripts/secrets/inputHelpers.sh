#!/usr/bin/env bash
# Shared input helpers for the secret-setup scripts.
# All helpers re-prompt until a non-empty value is entered, so an accidental
# empty paste can never be stored as a Pulumi secret/config value.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/inputHelpers.sh"
#   read_secret_var   TOKEN  "Enter hcloud token"      # hidden, single line
#   read_line_var     USER   "SMTP username"           # visible, single line
#   read_multiline_var KEY   "Paste the private key"   # multi-line until Ctrl+D
# then:
#   printf '%s' "$TOKEN" | pulumi config set --secret hcloudToken

# Hidden single-line input, non-empty.
read_secret_var() {
  local __var="$1" __prompt="$2" __val=""
  while true; do
    read -rsp "$__prompt: " __val; echo
    [[ -n "$__val" ]] && break
    echo "  Error: value cannot be empty. Try again." >&2
  done
  printf -v "$__var" '%s' "$__val"
}

# Visible single-line input, non-empty.
read_line_var() {
  local __var="$1" __prompt="$2" __val=""
  while true; do
    read -rp "$__prompt: " __val
    [[ -n "$__val" ]] && break
    echo "  Error: value cannot be empty. Try again." >&2
  done
  printf -v "$__var" '%s' "$__val"
}

# Multi-line paste (terminated by Ctrl+D), non-empty (ignoring whitespace).
read_multiline_var() {
  local __var="$1" __prompt="$2" __val=""
  while true; do
    echo "$__prompt (paste, then press Enter and Ctrl+D):" >&2
    __val="$(cat)"
    [[ -n "${__val//[[:space:]]/}" ]] && break
    echo "  Error: input cannot be empty. Try again." >&2
  done
  printf -v "$__var" '%s' "$__val"
}
