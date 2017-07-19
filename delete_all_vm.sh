#!/bin/bash
source /home/stack/overcloudrc
echo "delete instances"
for id in $(nova list | egrep 'demo|rhel' | awk -F'|' '{print $2}' | awk '{print $1}'); do
   nova delete $id
done

sleep 3
echo "delete unused ports"
for id in $(neutron port-list | grep ip_address | egrep -v '10.1.1.1"|10.1.1.2"' | awk -F'|' '{print $2}' | awk '{print $1}'); do
   neutron port-delete $id
done

sleep 3
echo "delete provider subnets"
for id in $(neutron subnet-list | grep provider | awk -F'|' '{print $2}' | awk '{print $1}'); do
   neutron subnet-delete $id
done

sleep 3
echo "delete provider nets"
for id in $(neutron net-list | grep provider | awk -F'|' '{print $2}' | awk '{print $1}'); do
   neutron net-delete $id
done

