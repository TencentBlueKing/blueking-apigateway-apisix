FROM tencentos/tencentos4-minimal:4.4-v20250613

ARG APISIX_VERSION=3.13.0
LABEL apisix_version="${APISIX_VERSION}"

# 1. yum install
COPY ./src/build/yum.repos.d/ /etc/yum.repos.d/
RUN sed -i 's/$releasever/8/g' /etc/yum.repos.d/apache-apisix.repo && sed -i 's/$releasever/8/g' /etc/yum.repos.d/openresty.repo
RUN yum clean packages
# you can add more tools for debug
# alreay on image: ifconfig nslookup dig ip ss route
# install openresty & apisix
RUN yum install -y apisix-${APISIX_VERSION} && \ 
    yum install -y tar m4 findutils procps less iproute traceroute telnet lsof net-tools tcpdump mtr vim bind-utils libyaml-devel hostname gawk iputils python3 python3-pip sudo && \
    yum install -y wget unzip patch make

# 2. install sentrylogs
RUN curl -LJ https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq && chmod 755 jq && mv jq /usr/bin/jq
RUN pip3 install sentrylogs

WORKDIR /usr/local/apisix

# 3. install luarocks and install lua libs
RUN wget https://raw.githubusercontent.com/apache/apisix/${APISIX_VERSION}/utils/linux-install-luarocks.sh && \
    sed -i 's/3.8.0/3.12.0/g' linux-install-luarocks.sh && \
    bash linux-install-luarocks.sh && \
    rm linux-install-luarocks.sh
RUN luarocks install multipart --tree=/usr/local/apisix/deps && \
    rm -rf /root/.cache/luarocks/ || echo "no /root/.cache/luarocks to clean"


# 4. copy files and patch
RUN mkdir -p /data/bkgateway/bin && rm -rf /usr/local/apisix/logs/*

ADD ./src/build/bin/apisix-start.sh ./src/build/bin/sentrylogs-daemonize.sh /data/bkgateway/bin/
ADD ./src/apisix/plugins/ /usr/local/apisix/apisix/plugins/
ADD ./src/build/patches /usr/local/apisix/patches
RUN ls /usr/local/apisix/patches | sort | xargs -I __patch_file__ sh -c 'cat ./patches/__patch_file__ | patch -t -p1'

RUN chmod 755 /data/bkgateway/bin/* && chmod 777 /usr/local/apisix/logs

# 6. clean up
RUN yum remove -y wget unzip patch make && yum clean all && rm -rf /var/cache/yum

CMD ["sh", "-c", "/usr/bin/apisix init && /usr/bin/apisix init_etcd && /usr/local/openresty/bin/openresty -p /usr/local/apisix -g 'daemon off;'"]

STOPSIGNAL SIGQUIT
