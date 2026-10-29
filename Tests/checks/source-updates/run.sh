#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
python3 "$here/check.py" "$root"
