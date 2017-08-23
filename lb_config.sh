#!/bin/bash

## USER-DEFINED VARIABLES
# docker image containing the service to be load-balanced
INSTANCE_IMG=httpd
# number of service instances desired
NUM_INSTANCES=3
# port running on instance
INSTANCE_PORT=80
# port to be exposed on load-balancer
LB_PORT=80
# container names
INSTANCE_CTR_PREFIX=web
LB_CTR_NAME=lb
# name of routable (external) network
# this needs to be defined on your VCH using the '--container-network' option
# use 'docker network ls' to list available external networks
EXTERNAL_NET=routable

## NO NEED TO MODIFY BEYOND THIS POINT
# initialize haproxy.cfg with defaults
echo -e global'\n'\
'\t'maxconn\ 256'\n'\
'\t'log\ 127.0.0.1:514\ local0'\n'\
defaults'\n'\
'\t'mode\ http'\n'\
'\t'timeout\ connect\ 5000ms'\n'\
'\t'timeout\ client\ 50000ms'\n'\
'\t'timeout\ server\ 5000ms'\n'\
'\t'log\ global'\n'\
frontend\ http-in'\n'\
'\t'bind\ \*:$LB_PORT'\n'\
'\t'default_backend\ servers'\n'\
backend\ servers > haproxy.cfg

# pull the images
docker pull $INSTANCE_IMG
docker pull haproxy:1.7

# create a user-defined bridge for the services
# note - this will fail if the network already exists
docker network create $INSTANCE_CTR_PREFIX-net

# start the number of instances defined above
for i in $(seq "${NUM_INSTANCES}"); do
  # run web instance
  docker run -d -p $INSTANCE_PORT --name $INSTANCE_CTR_PREFIX-${i} --net $INSTANCE_CTR_PREFIX-net $INSTANCE_IMG
  # add entry in load-balancer config file
  echo -e '\t'server\ server${i}\ $INSTANCE_CTR_PREFIX-${i}:$INSTANCE_PORT\ maxconn\ 32 >> haproxy.cfg
done

# create the load-balancer
# connect it to a routable network where it will expose the service
docker create --name $LB_CTR_NAME --net $EXTERNAL_NET haproxy:1.7
# connect to user-defined bridge network
# note - it resolves the instances by name over this network
docker network connect $INSTANCE_CTR_PREFIX-net $LB_CTR_NAME
# copy haproxy config file to the container
docker cp haproxy.cfg $LB_CTR_NAME:/usr/local/etc/haproxy/haproxy.cfg
# start the load-balancer
docker start $LB_CTR_NAME

# Grab the load-balancer's public IP Address
echo -e '\n'\Service\ is\ available\ at
docker inspect -f "{{ .NetworkSettings.Networks.$EXTERNAL_NET.IPAddress}}" $LB_CTR_NAME
echo -e on\ port\ $LB_PORT