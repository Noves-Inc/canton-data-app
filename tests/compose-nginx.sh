#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$repo_root/docker-compose/nginx/cda.conf.example"

fail() {
  printf 'compose NGINX test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  grep -Fq -- "$expected" "$config" ||
    fail "$config does not contain: $expected"
}

[[ -f "$config" ]] || fail "$config does not exist"

assert_contains 'server_name data.example.com;'
assert_contains 'server_name api.data.example.com;'
assert_contains 'resolver 127.0.0.11'
assert_contains 'noves-canton-frontend-v4:3000'
assert_contains 'noves-canton-backend-v4:8090'
assert_contains 'proxy_http_version 1.1;'
assert_contains 'proxy_set_header Upgrade $http_upgrade;'
assert_contains 'proxy_set_header Connection "upgrade";'
assert_contains 'proxy_set_header Host $host;'
assert_contains 'proxy_set_header X-Forwarded-Host $host;'
assert_contains 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
assert_contains 'proxy_set_header X-Forwarded-Proto $scheme;'
assert_contains 'return 301 https://$host$request_uri;'

open_braces="$(tr -cd '{' <"$config" | wc -c | tr -d ' ')"
close_braces="$(tr -cd '}' <"$config" | wc -c | tr -d ' ')"
[[ "$open_braces" == "$close_braces" ]] ||
  fail "unbalanced braces: $open_braces open, $close_braces closed"

printf 'compose NGINX tests passed\n'
