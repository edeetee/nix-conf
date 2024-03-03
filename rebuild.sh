#!/usr/bin/env bash

cd "$(dirname "$0")"

set -e

nixos-rebuild "$@"
git add .
git commit -a
git push
