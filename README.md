# Deploying a service behind a load-balancer

This section gives an example of deploying multiple intances of a given service behind a load-balancer that provides a single IP address for access and load distribution.

We will use a scripting approach that will allow us to generate the necessary load-balancer configuration file dynamically based on certain user-defined parameters.

To deploy a service behind a load-balancer, we need to consider:
1. Which load-balancer to use?
2. What docker image will I use to instantiate the service?
3. How many instances of the service of the service to I want to run?
4. What ports from the container instances do I need to load-balance?
5. What port on the load-balancer will be used to provide the service?

In this example, we will use [HAProxy](http://www.haproxy.org/) as the load-balancing solution. HAProxy is a free, open source load-balancer for TCP and HTTP-based applications.

For publishing the service out from the load-balancer, we will leverage vSphere Integrated Container's ability to connect containers directly to vSphere Port Groups and not through the Container Host. This allows for clean separation between networks used for inter-process communications and networks used to publish services externally. You can find more inforamtion on how to set this up [here](https://blogs.vmware.com/vsphere/2017/02/connecting-containers-directly-external-networks.html).

Here is an example script to set this up:

```
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
```

Let's break this down to better understand what this script does.

## User-defined variables

```
[...]
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
[...]
```

As a user of the script this is the only section you need to modify. 
- INSTANCE_IMG - this is the docker image you wish to use for your service instances. In this example we use a simple, unmodified `httpd` image from Docker Hub.
- NUM_INSTANCES - this is the number of instances that will be running behind the load-balancer.
- INSTANCE_PORT - the port that your service listens on. This will be injected in our HAProxy configuration file. This example uses a simple web server listening on port 80.
- LB_PORT - the port to use to publish the service on the load-balancer. This will be injected into the HAProxy configuration file. 
- INSTANCE\_CTR\_PREFIX and LB\_CTR_NAME - these are arbitrary names to identify the running instances and the load-balancer, respectively.

The script will use these parameters to pull the images, instantiate the user-defined number of instances, generate the HAProxy configuration file and create the load-balancer.

## Pulling the images and creating the user-defined bridge network

```
[...]
# pull the images
docker pull $INSTANCE_IMG
docker pull haproxy:1.7

# create a user-defined bridge for the services
# note - this will fail if the network already exists
docker network create $INSTANCE_CTR_PREFIX-net
[...]
```

First we pull the 2 necessary images (INSTANCE_IMG that was defined above and haproxy:1.7).

Then we define a bridge network to be used for communications between our instances and the load-balancer. This user-defined network has an embedded DNS server that allows us to reference the containers by name when configuring the load-balancer.

## Instantiating the containers

```
[...]
# start the number of instances defined above
for i in $(seq "${NUM_INSTANCES}"); do
  # run web instance
  docker run -d -p $INSTANCE_PORT --name $INSTANCE_CTR_PREFIX-${i} --net $INSTANCE_CTR_PREFIX-net $INSTANCE_IMG
  # add entry in load-balancer config file
  echo -e '\t'server\ server${i}\ $INSTANCE_CTR_PREFIX-${i}:$INSTANCE_PORT\ maxconn\ 32 >> haproxy.cfg
done
[...]
```

This simple `for` loop repeats NUM_INSTANCES times. For each iteration, it:
1. runs a container using the image defined in INSTANCE\_IMG above. For the name, we use INSTANCE\_CTR_PREFIX followed by a nmuber (e.g. web-1). We connect it to our user-defined bridge and we run it detached (`-d`)
2. we add an entry for this instance in our HAProxy configuration file.

## Starting the load-balancer

```
[...]
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
[...]
```

Here we use the `docker create` command (rather than `docker run`) because we want to connect our load-balancer to two networks and because we want to copy our load-balancer configuration file to the container before we start it up.

## Running the script

Before running the script, you need to point your docker client to a VCH endpoint. This is done by setting `DOCKER_HOST=<endpoint-ip>:<port>`.

After you run the script, you need to find the load-balancer's public IP address. You can find out by running:

```
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lb
```