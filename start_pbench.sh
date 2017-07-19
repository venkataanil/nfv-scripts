#!/bin/bash

error ()
{
  echo $* 1>&2
  exit 1
}

comupte_tools=(proc-sched_debug proc-interrupts sar openvswitch iostat)
vm_tools=(proc-sched_debug proc-interrupts sar iostat)
pbench-kill-tools
pbench-clear-tools

if [[ $# -eq 0 ]]; then
  
source /home/stack/stackrc || error "can't load stackrc"

#echo "start tools on controllers"
#for node in $(nova list | sed -n -r 's/.*control.*ctlplane=([.0-9]+).*/\1/ p'); do
#  for tool in sar; do
#    pbench-register-tool --remote=$node --name=$tool
#  done
#done
#
echo "start tools on computes"
for node in $(nova list | sed -n -r 's/.*compute.*ctlplane=([.0-9]+).*/\1/ p'); do
  for tool in ${comupte_tools[@]}; do
    pbench-register-tool --remote=$node --name=$tool
  done
done

echo "start tools on VMs"
source /home/stack/overcloudrc || error "can't load overcloudrc"
for node in $(nova list | sudo sed -n -r 's/.*(demo[0-9]+).*access=([.0-9]+).*/\2/p'); do
  #ssh root@$node "sed -i -e s/^collect_sos/\#collect_sos/ /opt/pbench-agent/util-scripts/pbench-sysinfo-dump" 
  for tool in ${vm_tools[@]}; do
    pbench-register-tool --remote=$node --name=$tool
  done
done

else
source /home/stack/overcloudrc || error "can't load overcloudrc"
nova show $1 || error "can't load overcloudrc"
node=$(nova show $1 | grep hypervisor_hostname | sed -n -r 's/.* (\S*compute-[0-9]+).*/\1/p')
for tool in ${comupte_tools[@]}; do
  pbench-register-tool --remote=$node --name=$tool
done
ssh root@$1 "sed -i -e s/^collect_sos/\#collect_sos/ /opt/pbench-agent/util-scripts/pbench-sysinfo-dump" 
for tool in ${vm_tools[@]}; do
  pbench-register-tool --remote=$1 --name=$tool
done
fi
