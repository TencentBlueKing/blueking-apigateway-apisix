#!/usr/bin/bash

resty_opts=""
busted_opts=""
name=""

while getopts ":cxmjn:" opt; do
    case $opt in
        c)
            busted_opts+="--coverage"
            rm -rf coverage-reporter luacov.stats.out || true
            mkdir -p coverage-reporter
            cat > .luacov << EOF
reporter = "html"
reportfile = "luacov.report.html"
EOF
        ;;
        m)
            resty_opts+="--valgrind"
        ;;
        n)
            name=$OPTARG
        ;;
        j)
            resty_opts+="-j v"
        ;;
        x)
            set -x
        ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
        ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
        ;;
    esac
done

resty ${resty_opts} \
-c 4096 \
--errlog-level error \
--http-include ./conf/nginx.conf \
-I . \
./tests/busted_runner.lua ${busted_opts} \
--verbose \
--shuffle \
--helper ./tests/busted_helper.lua \
./tests/test*.lua ./tests/**/test*.lua

status="$?"

if [ "${status}" != 0 ]; then
    exit 1
fi

if [ -f "luacov.stats.out" ]; then
    luacov-console
    luacov-console -s
fi

if [ -f "luacov.report.html" ]; then
    mv luacov.report.html "coverage-reporter/${name}.html"
fi
