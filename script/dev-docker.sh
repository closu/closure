#!/usr/bin/env bash

# Script name
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")

# Script directory
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") >/dev/null && pwd)

# Project directory
PROJECT_DIR=$(dirname "${SCRIPT_DIR}")

docker volume create jekyll
docker run \
    -v "${PROJECT_DIR}:/srv/jekyll" -p 4000:4000 \
    -v "jekyll:/usr/local/bundle" \
    --rm -it jekyll/jekyll bash

# jekyll serve -D
