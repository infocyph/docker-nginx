#!/bin/sh
set -eu

/usr/local/bin/render-locals.sh

# fail fast if config is bad
nginx -t

# run CMD (nginx -g 'daemon off;')
exec "$@"
