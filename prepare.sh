#/bin/bash
# create n Vms, n specified by the first augument
set -x

error ()
{
  echo $* 1>&2
  exit 1
}

function get_vm_mac() {
# arg1: vm name
# arg2: network name
  local vm=$1
  local net=$2
  local vm_ip=$(openstack server show $vm | sed -n -r "s/.*$net=([.0-9]+).*/\1/p")
  local mac=$(neutron port-list --fixed_ips ip_address=${vm_ip} | sed -n -r "s/.*([a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}).*/\1/p")
  echo $mac
}

function start_instance() {
# arg1: instance name 
# arg2: provider 1 port-id
# arg3: provider 2 port-id
# arg4: access port-id
  local name=$1
  local id1=$2
  local id2=$3
  local id3=$4
  if [[ -z "$user_data" ]]; then
    nova boot --flavor nfv --image ${vm_image_name} --nic port-id=$id3 --nic port-id=$id1 --nic port-id=$id2 --key-name demo-key $name 
  else
    nova boot --flavor nfv --image ${vm_image_name} --nic port-id=$id3 --nic port-id=$id1 --nic port-id=$id2 --key-name demo-key --user-data $user_data $name 
  fi
  if [[ $? -ne 0 ]]; then
    echo nova boot failed
    exit 1
  fi
  echo instance $name started
}

if [ ! -f nfv_test.cfg ]; then
  error "nfv_test.cfg can't be found"
fi
source nfv_test.cfg

source /home/stack/overcloudrc || error "can't load overcloudrc"

#update nova quota to allow more core use and more network
project_id=$(openstack project show -f value -c id admin)
nova quota-update --instances $num_vm $project_id
nova quota-update --cores $(( $num_vm * 6 )) $project_id
neutron quota-update --tenant_id $project_id --network $(( $num_vm + 2 ))
neutron quota-update --tenant_id $project_id --subnet $(( $num_vm + 2 ))

if [ ! -d ${nfv_tmp_dir} ]; then
  echo "directory ${nfv_tmp_dir} not exits, creating"
  mkdir -p ${nfv_tmp_dir} || error "failed to create ${nfv_tmp_dir}"
fi

#download image if it not exits on local directory
vm_image_file="${nfv_tmp_dir}/${vm_image_file}"
if [ -f ${vm_image_file} ]; then
  echo "found image ${vm_image_file}"
else 
  echo "image ${vm_image_file} not found, downloading"
  wget $vm_image_url -O ${vm_image_file} || error "failed to download image"
fi

#modify image to use persistent interface naming
virt-edit -a ${vm_image_file} -e "s/net.ifnames=0/net.ifnames=1/g" /boot/grub2/grub.cfg || error "virt-edit failed"

#assume vm dhco port is always ens3
#it is ok the move fails in case this is not a new it was moved before
virt-customize -a ${vm_image_file} --run-command "mv /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-ens3" 2>/dev/null
#but if the following fail then we have to bail out
virt-edit -a ${vm_image_file} -e "s/eth0/ens3/g" /etc/sysconfig/network-scripts/ifcfg-ens3 || error "virt-edit failed"
# at this time, virt-cat and virt-ls can be used to doublecheck the change we made on the image

if ! openstack image list | grep ${vm_image_name}; then
  openstack image create --disk-format qcow2 --container-format bare   --public --file ${vm_image_file} ${vm_image_name} || error "failed to create image" 
fi

nova keypair-list | grep 'demo-key' || nova keypair-add --pub-key ~/.ssh/id_rsa.pub demo-key
openstack security group rule list | grep 22:22 || openstack security group rule create default --protocol tcp --dst-port 22:22 --src-ip 0.0.0.0/0
openstack security group rule list | grep icmp || openstack security group rule create default --protocol icmp

# to make sure the other HT sibling not used by instance, an alternative, might be used hw:cpu_thread_policy=isolate, --vcpus 3 (rather than 6)
if openstack flavor list | grep nfv; then
  openstack flavor delete nfv
fi
openstack flavor create nfv --id 1 --ram 4096 --disk 20 --vcpus 6

if [[ ${vnic_type} == "sriov" ]]; then
  nova flavor-key 1 set hw:cpu_policy=dedicated hw:mem_page_size=1GB hw:numa_nodes=1 hw:numa_mempolicy=preferred hw:numa_cpus.0=0,1,2,3,4,5 hw:numa_mem.0=4096
else   
  nova flavor-key 1 set hw:cpu_policy=dedicated hw:mem_page_size=1GB
  if [[ ${enable_HT} == "true" ]]; then
    nova flavor-key 1 set hw:cpu_thread_policy=prefer
  fi
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
  if [[ ${vnic_type} == "sriov" ]]; then
    neutron net-create provider-nfv$i --provider:network_type vlan --provider:physical_network sriov$((i % 2 + 1)) --provider:segmentation_id $((100 + $i)) --port_security_enabled=False
  else 
    neutron net-create provider-nfv$i --provider:network_type vlan --provider:physical_network dpdk$(($i % 2)) --provider:segmentation_id $((100 + $i)) --port_security_enabled=False
  fi
  neutron subnet-create --name provider-nfv$i --disable-dhcp --gateway 192.168.$i.254 provider-nfv$i 192.168.$i.0/24
done


neutron net-list > tmpfile
#access=$(cat tmpfile | grep access | awk -F'|' '{print $2}' | awk '{print $1}')
declare -a vmState

for i in $(eval echo "{1..$num_vm}"); do
  if [[ ${vnic_type} == "sriov" ]]; then
    vnic_option="--vnic-type direct"
  else 
    vnic_option=""
  fi
  provider1=$(openstack port create --network provider-nfv$((i - 1)) ${vnic_option} nfv$((i - 1))-port | awk '/ id/ {print $4}')
  provider2=$(openstack port create --network provider-nfv$i ${vnic_option} nfv$i-port | awk '/ id/ {print $4}')
  access=$(openstack port create --network access access-port-$i | awk '/ id/ {print $4}')
  start_instance demo$i $provider1 $provider2 $access
  vmState[$i]=0
done

for n in {0..1000}; do
  sleep 3
  nova list > tmpfile
  completed=1
  errored=0
  for i in $(eval echo "{1..$num_vm}"); do
    if [ ${vmState[$i]} -ne 1 ]; then
      if grep demo$i tmpfile | egrep 'ACTIVE'; then
        vmState[$i]=1
      elif grep demo$i tmpfile | egrep 'ERROR'; then
        errored=1
        break
      else
        completed=0
      fi
    fi
  done
  if (( $completed || $errored )); then
    break
  fi
done

if (( $errored )); then
  completed=0 
fi

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
  if [[ "$USER" == "stack" ]]; then
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m shell -a "> /root/.ssh/authorized_keys; echo $(sudo cat /home/stack/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys; echo $(sudo cat /root/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys"
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m lineinfile -a "name=/etc/ssh/sshd_config regexp='^UseDNS' line='UseDNS no'"
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m service -a "name=sshd state=restarted"
  else
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m shell -a "> /root/.ssh/authorized_keys; echo $(sudo cat /home/stack/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys; echo $(sudo cat /root/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys"
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m lineinfile -a "name=/etc/ssh/sshd_config regexp='^UseDNS' line='UseDNS no'"
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i nodes -m service -a "name=sshd state=restarted"
  fi
done

if [[ $vnic_type == "sriov" ]]; then
  ansible-playbook -i nodes repin_threads.yml --extra-vars "repin_kvm_emulator=${repin_kvm_emulator}" || error "failed to repin thread"
else
  ansible-playbook -i nodes repin_threads.yml --extra-vars "repin_ovs_nonpmd=${repin_ovs_nonpmd} repin_kvm_emulator=${repin_kvm_emulator} repin_ovs_pmd=${repin_ovs_pmd} pmd_vm_eth0=${pmd_vm_eth0} pmd_vm_eth1=${pmd_vm_eth1} pmd_vm_eth2=${pmd_vm_eth2} pmd_dpdk0=${pmd_dpdk0} pmd_dpdk1=${pmd_dpdk1} pmd_dpdk2=${pmd_dpdk2}" || error "failed to repin thread"
fi

if [[ $vnic_type == "sriov" ]]; then
  exit 0
fi

sleep 60
ansible-playbook -i nodes nfv.yml --extra-vars "run_pbench=${run_pbench} traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac} routing=${routing}" || error "failed to run NFV application"


# prepare test script
if [[ $traffic_loss_pct != 0 ]]; then
  echo $PWD/start_pbench.sh > start-pbench-trafficgen
fi

if [[ $routing == "vpp" ]]; then
  source $overcloudrc
  mac1=`get_vm_mac demo1 provider-nfv0`
  mac2=`get_vm_mac demo${num_vm} provider-nfv${num_vm}`
  echo pbench-trafficgen --config="pbench-trafficgen" --num-flows=128 --traffic-directions=bidirec --src-ips=192.168.0.100,192.168.${num_vm}.100 --dst-ips=192.168.${num_vm}.100,192.168.0.100 --flow-mods=src-ip --traffic-generator=moongen-txrx --devices=${traffic_gen_src_slot},${traffic_gen_dst_slot} --vlan-ids=${data_vlan_start},$((data_vlan_start+num_vm)) --search-runtime=${search_runtime} --validation-runtime=${validation_runtime} --max-loss-pct=${traffic_loss_pct} --dst-macs=$mac1,$mac2 >> start-pbench-trafficgen
else
  echo pbench-trafficgen --config="pbench-trafficgen" --num-flows=128 --traffic-directions=bidirec --src-ips=192.168.0.100,192.168.${num_vm}.100 --dst-ips=192.168.${num_vm}.100,192.168.0.100 --flow-mods=src-ip --traffic-generator=moongen-txrx --devices=${traffic_gen_src_slot},${traffic_gen_dst_slot} --vlan-ids=${data_vlan_start},$((data_vlan_start+num_vm)) --search-runtime=${search_runtime} --validation-runtime=${validation_runtime} --max-loss-pct=${traffic_loss_pct} >> start-pbench-trafficgen
fi

