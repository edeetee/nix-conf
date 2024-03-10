#!/usr/bin/env bash

set -e

cd "$(dirname "$0")"

sudo su

nixos-rebuild "$@"
git add .
git commit -a
git push

exit
