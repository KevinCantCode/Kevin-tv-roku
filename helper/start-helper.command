#!/bin/bash
# Double-click to start the Kevin TV converter. Leave the window open while watching; close it to stop.
cd "$(dirname "$0")"
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
exec /usr/bin/python3 kevintv_helper.py "$@"
