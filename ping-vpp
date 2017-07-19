#!/bin/bash
# usage: cmd --srcip <> --dstip <> --srcif <> --dstif <> --srcgw <> --dstgw <>
# interface can include vlanID in the format of if.vlan
# srcgw and dstgw is needed if the srcip and dstip are on different sunbet
# example: cmd --srcip 10.1.1.1  --dstip 20.1.1.2 --srcif eth1.20 --dstif eth2.100 --srcgw 10.1.1.5 --dstgw 20.1.1.5

execcmd=$0
while [[ $# -gt 1 ]]
do
key="$1"
case $key in
  --srcip)
  srcip=$2
  shift
  ;;
  --dstip)
  dstip=$2
  shift
  ;;
  --srcif)
  srcif=$2
  shift
  ;;
  --dstif)
  dstif=$2
  shift
  ;;
  --srcgw)
  srcgw=$2
  shift
  ;;
  --dstgw)
  dstgw=$2
  shift
  ;;
  *)
  echo "Usage: $execcmd --srcip <ip> --dstip <ip> --srcif <if> --dstif <if> --srcgw <gw> --dstgw <gw>"
  exit 1
  ;;
esac
shift
done

if [ -z "${srcip+1}" ]; then
  srcip=1.1.1.1
  echo "defaulting srcip=$srcip"
fi

if [ -z "${dstip+1}" ]; then
  dstip=1.1.1.2
  echo "defaulting dstip=$dstip"
fi

echo srcip=$srcip, dstip=$dstip, srcif=$srcif, dstif=$dstif, srcgw=$srcgw, dstgw=$dstgw

srcnet=$(echo $srcip | sed -r -n 's/([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3.0/p')
dstnet=$(echo $dstip | sed -r -n 's/([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3.0/p')

echo srcnet=$srcneti dstnet=$dstnet

if [[ "$srcnet" != "$dstnet" ]]; then
  if [[ -z "${srcnet+1}" || -z "${dstnet+1}" ]]; then
    echo "srcip and dstip on different subnet, need --srcgw --dstgw for gateway info"
    exit 1
  fi
fi

./unset.sh || exit 1

sendtag=$(echo "$srcif" | awk -F'.' '{print $2}')
recvtag=$(echo "$dstif" | awk -F'.' '{print $2}')
if [[ $sendtag != "" ]]; then
   sendif=$(echo "$srcif" | awk -F'.' '{print $1}')
   echo "xmt interface $sendif with tag $sendtag"
   ip link add link $sendif name $sendif.$sendtag type vlan id $sendtag || exit 1
   ip link set up $sendif
   sendif=$sendif.$sendtag
else
   echo "no sending tag"
   sendif=$srcif
fi

if [[ $recvtag != "" ]]; then
   recvif=$(echo "$dstif" | awk -F'.' '{print $1}')
   echo "rcv interface $recvif with tag $recvtag"
   ip link add link $recvif name $recvif.$recvtag type vlan id $recvtag || exit 1
   ip link set up $recvif
   recvif=$recvif.$recvtag
else   
   recvif=$dstif
fi

ip netns delete red 2> /dev/null
ip netns delete blue 2> /dev/null

ip netns add red
ip netns add blue
ip link set $sendif netns red
ip link set $recvif netns blue
ip netns exec red ip a add $srcip/24 dev $sendif
ip netns exec blue ip a add $dstip/24 dev $recvif
ip netns exec red ip link set $sendif up
ip netns exec blue ip link set $recvif up

srcnet=$(echo $srcip | sed -r -n 's/([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3.0/p')
dstnet=$(echo $dstip | sed -r -n 's/([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3.0/p')

if [ "$srcnet" != "$dstnet" ]; then
  ip netns exec red route add -net $dstnet netmask 255.255.255.0 gw $srcgw
  ip netns exec blue route add -net $srcnet netmask 255.255.255.0 gw $dstgw
fi

ping_received=$(ip netns exec red ping -c 3 -W 2 $dstip | grep received | awk '{print $4}')
if [[ $ping_received > 0 ]]; then
   echo success
else
   echo fail
fi
ip netns exec red ip link set $sendif netns 1
ip netns exec blue ip link set $recvif netns 1
sleep 1
if [[ $sendtag != "" ]]; then
   ip link delete $sendif
fi

if [[ $recvtag != "" ]]; then
   ip link delete $recvif
fi

ip netns delete red
ip netns delete blue

