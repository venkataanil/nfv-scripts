#/bin/bash
# create n Vms, n specified by the first augument

error ()
{
  echo $* 1>&2
  exit 1
}

if [ ! -f nfv_test.cfg ]; then
  error "nfv_test.cfg can't be found"
fi
source nfv_test.cfg

traffic_src_mac=$(dmesg | sed -r -n "s/.*${traffic_gen_src_slot}:.*([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})/\1/p" | tail -1)
traffic_dst_mac=$(dmesg | sed -r -n "s/.*${traffic_gen_dst_slot}:.*([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})/\1/p" | tail -1)
echo traffic_src_mac=${traffic_src_mac}, traffic_dst_mac=${traffic_dst_mac}
if [[ -z "${traffic_src_mac}" || -z "{traffic_dst_mac}" ]]; then
  error "failed to get traffic gen mac address"
fi

[[ $# -eq 1 ]] || error "Usuage: $0 <number of instances to create>" 

num_vm=$1

source /home/stack/overcloudrc || error "can't load overcloudrc"

#update nova quota to allow more core use and more network
project_id=$(openstack project show -f value -c id admin)
nova quota-update --instances $num_vm $project_id
nova quota-update --cores $(( $num_vm * 4 )) $project_id
neutron quota-update --tenant_id $project_id --network $(( $num_vm + 2 ))
neutron quota-update --tenant_id $project_id --subnet $(( $num_vm + 2 ))

if ! openstack image list | grep ${vm_image_name}; then
  openstack image create --disk-format qcow2 --container-format bare   --public --file ${vm_image_file} ${vm_image_name} || error "failed to create image" 
fi

nova keypair-list | grep 'demo-key' || nova keypair-add --pub-key ~/.ssh/id_rsa.pub demo-key
openstack security group rule list | grep 22:22 || openstack security group rule create default --protocol tcp --dst-port 22:22 --src-ip 0.0.0.0/0
openstack security group rule list | grep icmp || openstack security group rule create default --protocol icmp

if ! openstack flavor list | grep nfv; then 
  openstack flavor create nfv --id 1 --ram 4096 --disk 20 --vcpus 4
  nova flavor-key 1 set hw:cpu_policy=dedicated
  nova flavor-key 1 set hw:mem_page_size=1GB
fi

if [[ ${enable_HT} == "true" ]]; then
  nova flavor-key 1 set hw:cpu_thread_policy=prefer
fi

if [[ ${enable_multi_queue} == "true" ]]; then
  nova flavor-key 1 set vif_multiqueue_enabled=true
  openstack image set ${vm_image_name} --property hw_vif_multiqueue_enabled=true
fi

if ! neutron net-list | grep access; then
#  neutron net-create access --provider:network_type flat  --provider:physical_network access
  neutron net-create access --provider:network_type vlan --provider:physical_network access --provider:segmentation_id 200 --port_security_enabled=False
  neutron subnet-create --name access --dns-nameserver 10.35.28.28 access 10.1.1.0/24
fi

for i in $(eval echo "{0..$num_vm}"); do
  neutron net-create provider-nfv$i --provider:network_type vlan --provider:physical_network dpdk$(($i % 2)) --provider:segmentation_id $((100 + $i)) --port_security_enabled=False
  sleep 1
  neutron subnet-create --name provider-nfv$i --disable-dhcp --gateway 192.168.$i.254 provider-nfv$i 192.168.$i.0/24
done

neutron net-list > tmpfile
access=$(cat tmpfile | grep access | awk -F'|' '{print $2}' | awk '{print $1}')
declare -a providers
declare -a vmState
declare -a retries
declare -a duration
declare -a port

for i in $(eval echo "{1..$num_vm}"); do
  provider1=$(cat tmpfile | grep provider-nfv$((i - 1)) | awk -F'|' '{print $2}' | awk '{print $1}')
  provider2=$(cat tmpfile | grep provider-nfv$i | awk -F'|' '{print $2}' | awk '{print $1}')
  echo excuting "nova boot --flavor nfv --image ${vm_image_name} --nic net-id=$access --nic net-id=$provider1 --nic net-id=$provider2 --key-name demo-key demo$i"
    nova boot --flavor nfv --image ${vm_image_name} --nic net-id=$access --nic net-id=$provider1 --nic net-id=$provider2 --key-name demo-key demo$i
  if [[ $? -ne 0 ]]; then
    echo "VM start immediately failed"
    nova show demo$i 
    exit 1
  fi
  echo "demo$i started, wait for active status"
  providers[$((i-1))]=$provider1
  providers[$i]=$provider2
  vmState[$i]=0
  retries[$i]=0
  duration[$i]=0
done

# check to make sure all VM complete with ACTIVE
for n in {0..1000}; do
  sleep 3
  nova list > tmpfile
  completed=1
  for i in $(eval echo "{1..$num_vm}"); do
    if [ ${vmState[$i]} -ne 1 ]; then
      if grep demo$i tmpfile | egrep 'ACTIVE'; then
        vmState[$i]=1
      elif grep demo$i tmpfile | egrep 'ERROR'; then
        completed=0
        nova show demo$i
        if [ ${retries[$i]} -lt 10 ]; then
          intcount=0
          for pID in $(nova interface-list demo$i | egrep '10.1|192.168' | awk -F'|' '{print $3}' | awk '{print $1}'); do
            port[$intcount]=$pID
            ((++intcount))
          done
          nova delete demo$i
          sleep 2
          for ((k=0; k<$intcount; k++)); do
            neutron port-delete ${port[$k]} 2>/dev/null
            sleep 1
          done
          nova boot --flavor nfv --image ${vm_image_name} --nic net-id=$access --nic net-id=${providers[((i-1))]} --nic net-id=${providers[$i]} --key-name demo-key demo$i
          ((++retries[$i]))
          duration[$i]=0
        else
          echo failed to start instance demo$i for ${retries[$i]} times
          exit 1
        fi
      else
        completed=0
        ((++duration[$i]))
        if [ ${duration[$i]} -gt 200 ]; then
        # this instance took 600s not completed, let's kill and restart it
          intcount=0
          for pID in $(nova interface-list demo$i | egrep '10.1|192.168' | awk -F'|' '{print $3}' | awk '{print $1}'); do
            port[$intcount]=$pID
            ((++intcount))
          done
          nova delete demo$i
          sleep 2
          for ((k=0; k<$intcount; k++)); do
            neutron port-delete ${port[$k]} 2>/dev/null
            sleep 1
          done
          nova boot --flavor nfv --image ${vm_image_name} --nic net-id=$access --nic net-id=${providers[((i-1))]} --nic net-id=${providers[$i]} --key-name demo-key demo$i
        fi
      fi
    fi
  done
  if [ $completed -eq 1 ]; then
    break
  fi
done

if [ $completed -ne 1 ]; then
  echo failed to start all the instances
  exit 1
fi


# update /etc/hosts entry with instances
echo "update /etc/hosts entry with instance names"
sudo sed -i -r '/vm/d' /etc/hosts
sudo sed -i -r '/demo/d' /etc/hosts
nova list | sudo sed -n -r 's/.*(demo[0-9]+).*access=([.0-9]+).*/\2 \1/p' | sudo tee --append /etc/hosts >/dev/null

# record all VM's access info in ansible inventory file
echo "record all nodes access info for ansible"
echo "[VMs]" > nodes 
nova list | sed -n -r 's/.*(demo[0-9]+).*access=([.0-9]+).*/\1 ansible_host=\2/ p' >> nodes

vm_num=$(nova list | grep demo | wc -l)

cat <<EOF >>nodes
[VMs:vars]
ansible_connection=ssh 
ansible_user=root 
ansible_ssh_pass=100yard-
vm_num=${vm_num}
EOF

source /home/stack/stackrc || error "can't load stackrc"
echo "[computes]" >> nodes
nova list | sed -n -r 's/.*compute.*ctlplane=([.0-9]+).*/\1/ p' >> nodes
echo "[controllers]" >> nodes
nova list | sed -n -r 's/.*control.*ctlplane=([.0-9]+).*/\1/ p' >> nodes
cat <<EOF >>nodes
[computes:vars]
ansible_connection=ssh
ansible_user=heat-admin
ansible_become=true
[controllers:vars]
ansible_connection=ssh
ansible_user=heat-admin
ansible_become=true
EOF

# check all VM are reachable by ping
# try 30 times
for n in $(seq 30); do
  reachable=1
  for i in $(seq $vm_num); do
    ping -q -c5 demo$i || reachable=0
  done
  if [ $reachable -eq 1 ]; then
    break
  fi
  sleep 1
done      

[ $reachable -eq 1 ] || error "not all VM pingable"

# make sure remote ssh port is open
for n in $(seq 30); do
  reachable=1
  for i in $(seq $vm_num); do
     timeout 1 bash -c "cat < /dev/null > /dev/tcp/demo$i/22" || reachable=0
  done
  if [ $reachable -eq 1 ]; then
    break
  fi
  sleep 1
done

[ $reachable -eq 1 ] || error "not all VM ssh port open"

# upload ssh key to all nodes 
echo "update authorized ssh key on nodes"
for host in computes controllers VMs; do
  ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m shell -a "> /root/.ssh/authorized_keys; echo $(sudo cat /home/stack/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys; echo $(sudo cat /root/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys"
  ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m lineinfile -a "name=/etc/ssh/sshd_config regexp='^UseDNS' line='UseDNS no'"
  ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m service -a "name=sshd state=restarted"
done

ansible-playbook -i nodes --extra-vars "run_pbench=${run_pbench}" nfv.yml

# deploy VPP inside instances
ansible-playbook -i nodes vm.yml --extra-vars "traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac} routing=${routing} run_pbench=${run_pbench}" || error "failed to run NFV application"

#ansible-playbook -i nodes repin_threads.yml --extra-vars "repin_ovs_nonpmd=${repin_ovs_nonpmd} repin_kvm_emulator=${repin_kvm_emulator}" || error "failed to repin thread"

mac1=$(cat vars/demo1_macs | sed -r -n "s/.*mac1=(.*)/\1/p") || error "failed to parse vars/demo1_macs"
mac2=$(cat vars/demo${num_vm}_macs | sed -r -n "s/.*mac2=(.*)/\1/p") || error "failed to parse vars/demo${num_vm}_macs"

# prepare test script
txrx_cmd="sudo ./MoonGen/build/MoonGen ./txrx.lua --size=${data_pkt_size} \
          --devices=0,1 --runTime=30 --srcIps=192.168.0.100,192.168.${num_vm}.100 \
          --dstIps=192.168.${num_vm}.100,192.168.0.100 \
          --dstMacs=${mac1},${mac2} --calibrateTxRate=0 \
          --vlanIds=${data_vlan_start},$((data_vlan_start+num_vm)) \
          --bidirectional=${traffic_bidirectional} --rate=${traffic_rate_init} \
          --nrFlows=128 --flowMods=srcIp"
binary_search_cmd="sudo ./binary-search.py --frame-size=${data_pkt_size} \
          --run-bidirec=${traffic_bidirectional} --search-runtime=30 \
          --validation-runtime=120 --rate=${traffic_rate_init} \
          --src-ips-list=192.168.0.100,192.168.${num_vm}.100 \
          --dst-ips-list=192.168.${num_vm}.100,192.168.0.100 \
          --dst-macs-list=${mac1},${mac2}  \
          --vlan-ids-list=${data_vlan_start},$((data_vlan_start+num_vm)) \
          --max-loss-pct=${traffic_loss_pct} \
          --num-flows=128 --use-src-ip-flows=1 --use-dst-ip-flows=0 \
          --use-src-mac-flows=0 --use-dst-mac-flows=0"

if [[ ${run_pbench} == "yes" ]]; then
cat > ${traffic_gen_dir}/run_txrx.sh <<EOF
#!/bin/bash
$PWD/start_pbench.sh
pbench-clear-results
pbench-user-benchmark --config="${pbench_benchmark_name}" -- ${txrx_cmd}
pbench-move-results
EOF
cat > ${traffic_gen_dir}/start_binary_search.sh <<EOF
#!/bin/bash
$PWD/start_pbench.sh
pbench-clear-results
pbench-user-benchmark --config="${pbench_benchmark_name}" -- ${binary_search_cmd}
pbench-move-results
EOF
else
cat > ${traffic_gen_dir}/run_txrx.sh <<EOF
#!/bin/bash
${txrx_cmd}
EOF
cat > ${traffic_gen_dir}/start_binary_search.sh <<EOF
#!/bin/bash
${binary_search_cmd}
EOF
fi

chmod 777 ${traffic_gen_dir}/run_txrx.sh

chmod 777 ${traffic_gen_dir}/start_binary_search.sh

echo "change directory to ${traffic_gen_dir} and run run_txrx.sh or start_binary_search.sh"

