#!/bin/bash

run_stamp="$(date '+%Y%m%d-%H%M%S')"

./nginx-health-check.sh --mode node --bundle-dir "$PWD/nginx-check-node-${run_stamp}" --include-raw --delta-seconds 30
