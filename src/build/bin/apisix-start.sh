#!/bin/sh
echo "starting......"

# if standaloneConfigPath not empty, watch the path
if [ x"${standaloneConfigPath}" != x"" ]
then
    echo "it's standalone mode, will watch config file first, then start apisix"
    if [ ! -f /usr/local/apisix/conf/apisix.yaml ]
    then
        echo "generate an empty apisix.yaml, while the operator not sync the data into apisix.yaml"
        printf "routes: []\n#END" > /usr/local/apisix/conf/apisix.yaml
    fi

    echo "start config-watcher for ${standaloneConfigPath}"
    sh /data/bkgateway/bin/config-watcher-start.sh "-sourcePath ${standaloneConfigPath} -destPath /usr/local/apisix/conf -files apisix.yaml" &
    echo "config-watcher for ${standaloneConfigPath} started"
fi

# start nginx error to sentry
if [ x"${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" != x"" ]
then
    echo "start sentrylogs to ship nginx error log to sentry"
    SENTRY_DSN="${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" NGINX_ERROR_PATH="/usr/local/apisix/logs/error.log" sentrylogs --daemonize

    # start a daemon to check sentrylogs, the sentrylogs will only process the `tail` records, so it's safe to restart it
    sh /data/bkgateway/bin/sentrylogs-daemonize.sh &
fi

echo "start config-watcher for ${apisixDebugConfigPath}(note: will wait until the container quit)"
# note the shell will wait here, so, YOU SHOULD NOT PUT ANY COMMANDS AFTER HERE
sh /data/bkgateway/bin/config-watcher-start.sh "-sourcePath ${apisixDebugConfigPath} -destPath /usr/local/apisix/conf -files debug.yaml -isConfigMap" &

echo "start apisix"
/usr/bin/apisix init && /usr/bin/apisix init_etcd && /usr/local/openresty/bin/openresty -p /usr/local/apisix -g 'daemon off;'

echo "quit"
