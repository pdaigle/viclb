#!/bin/bash

# define number of web server instances
NUM_WEB_INSTANCES=3
# name of routable (external) network
EXTERNAL_NET=routable
# container names
WEB_CTR_PREFIX=web
LB_CTR_NAME=lb

# initialize haproxy.cfg with template
cp haproxy.cfg.tmpl haproxy.cfg

# pull the images first
docker pull httpd
docker pull haproxy:1.7

# create a user defined bridge for the web services. This will fail if the network already exists.
docker network create web-net

# start the number of web instances defined above
for i in $(seq "${NUM_WEB_INSTANCES}"); do
  # run web instance
  docker run -d -p 80 --name $WEB_CTR_PREFIX-${i} --net web-net httpd
  # add entry in load-balancer config file
  echo -e '\t'server\ server1\ $WEB_CTR_PREFIX-${i}:80\ maxconn\ 32 >> haproxy.cfg
done

# start the load-balancer - note it resolves the web instances by name over web-net
docker create --name $LB_CTR_NAME --net $EXTERNAL_NET haproxy:1.7
# connect to web-net for communications with web instances
docker network connect web-net $LB_CTR_NAME
# copy haproxy config file to container before starting it
docker cp haproxy.cfg $LB_CTR_NAME:/usr/local/etc/haproxy/haproxy.cfg

docker start $LB_CTR_NAME
