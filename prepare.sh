#/bin/bash
# create n Vms, n specified by the first augument
set -x
export ANSIBLE_HOST_KEY_CHECKING=False

error ()
{
  echo $* 1>&2
  exit 1
}

function delete_nfv_instances () {
  source ${overcloudrc} || error "can't load overcloudrc"
  echo "delete instances"
  for id in $(openstack server list \
                 | egrep "demo" \
                 | awk -F'|' '{print $2}' \
                 | awk '{print $1}'); do
    openstack server delete $id
  done

  echo "delete unused ports"
  for id in $(neutron port-list | grep ip_address \
                                | egrep -v '10.1.1.1"|10.1.1.2"' \
                                | awk -F'|' '{print $2}' \
                                | awk '{print $1}'); do
    neutron port-delete $id
  done

  echo "delete provider subnets"
  for id in $(neutron subnet-list | grep provider \
                                  | awk -F'|' '{print $2}' \
                                  | awk '{print $1}'); do
    neutron subnet-delete $id
  done

  echo "delete provider nets"
  for id in $(neutron net-list | grep provider \
                               | awk -F'|' '{print $2}' \
                               | awk '{print $1}'); do
    neutron net-delete $id
  done

}

function get_vm_mac() {
# arg1: vm name
# arg2: network name
  local vm=$1
  local net=$2
  local vm_ip=$(openstack server show $vm | sed -n -r "s/.*$net=([.0-9]+).*/\1/p")
  local mac=$(neutron port-list --fixed_ips ip_address=${vm_ip} \
              | sed -n -r "s/.*([a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}).*/\1/p")
  echo $mac
}

function get_mac_from_pci_slot () {
  #this function retrieve mac address from pci slot id. $1: slot number, $2: variable name to set the return value to
  local slot=$1
  local  __resultvar=$2
  local line=$(sudo dpdk-devbind -s | grep $slot)
  local kernel_driver
  local mac 
  if echo $line | grep igb; then
    kernel_driver=igb
  elif echo $line | grep i40e; then
    kernel_driver=i40e
  elif echo $line | grep ixgbe; then
    kernel_driver=ixgbe
  else
    error "failed to find kernel driver for pci slot $slot"
  fi

  # bind it to kernel to see what its mac address
  sudo dpdk-devbind -u $slot
  sudo dpdk-devbind -b ${kernel_driver} $slot
  mac=$(sudo dmesg | sed -r -n "s/.*${slot}:.*([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})/\1/p" | tail -1)
  eval $__resultvar=$mac
  # bind the port back to vfio-pci driver
  lsmod | grep vfio_pci || sudo modprobe vfio-pci
  sudo dpdk-devbind -b vfio-pci $slot
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

  local opt=""
  local hypervisor=""
  if [[ ! -z "$compute_node" ]]; then
    # is the node name even right? need full name(with domain) 
    hypervisor=$(openstack hypervisor list | grep $compute_node | awk '{print $4}')
    if [[ ! -z "hypervisor" ]]; then
      opt="$opt --availability-zone nova:$hypervisor"
    fi
  fi

  if [[ ! -z "$user_data" ]]; then
    opt="$opt --user-data $user_data"
  fi

  openstack server create --flavor nfv \
                          --image ${vm_image_name} \
                          --nic port-id="$id3" \
                          --nic port-id="$id1" \
                          --nic port-id="$id2" \
                          --key-name demo-key \
                          $opt $name 

  if [[ $? -ne 0 ]]; then
    echo nova boot failed
    exit 1
  fi
  echo instance $name started
}

function check_input() {
  if [ -z ${num_vm+x} ]; then
    echo "num_vm not set, default to: 1"
    num_vm=1
  fi
  if (( num_vm > 99 )); then
    error "num_vm: ${num_vm} invalid, can not exceed 99"
  fi

  if [ -z ${num_flows+x} ]; then
    echo "num_flows not set, default to: 128"
    num_flows=128
  fi
 
  if [ -z ${provider_network_type+x} ]; then 
    echo "provider_network_type not set, default to: flat"
    provider_network_type="flat"
  fi

  if [ -z ${access_network_type+x} ]; then
    echo "access_network_type not set, default to flat"
    access_network_type="flat"
  fi

  if [[ ${provider_network_type} == "vlan" ]]; then
    if [[ -z "${data_vlan_start}" ]]; then
      echo "data_vlan_start not set, use default: 100"
      data_vlan_start=100
    fi
  elif [[ ${provider_network_type} == "vxlan" ]]; then
    if [[ -z "${data_vxlan_start}" ]]; then
      echo "data_vxlan_start not set, use default: 100"
      data_vxlan_start=100
    fi
  elif [[ ${provider_network_type} != "flat" ]]; then
    error "invalid provider_network_type: ${provider_network_type}"
  fi 

  if [[ ${access_network_type} == "vlan" ]]; then
    if [[ -z "${access_network_vlan}" ]]; then
      echo "access_network_vlan not set, use default: 200"
      access_network_vlan=200
    fi
  elif [[ ${access_network_type} != "flat" ]]; then
    error "invalid access_network_type: ${access_network_type}"
  fi

  if [[ "$routing" == "testpmd" && "${vnic_type}" == "sriov" ]]; then
    routing="testpmd-sriov"
  fi 

  if [[ "$routing" == "testpmd" || "$routing" == "testpmd-sriov" ]]; then
    if [[ -z ${testpmd_fwd} ]]; then
      testpmd_fwd="io"
    fi
    case ${testpmd_fwd} in
      io|mac) ;;
      macswap)
        traffic_direction="unidirec"
        traffic_gen_dst_slot=${traffic_gen_src_slot}
        ;;
      *)
        error "invalid testpmd fwd: ${testpmd_fwd}"i
        ;;
    esac
  fi

  case ${traffic_direction} in
    bidirec|unidirec|revunidirec);;
    *) error "invalid traffic_direction: ${traffic_direction}";;
  esac

  if [ -z ${traffic_gen_extra_opt+x} ]; then 
    #traffic_gen_extra_opt unset
    traffic_gen_extra_opt=""
  fi 

  if [ -z ${stop_pbench_after+x}]; then
    stop_pbench_after="false"
  fi
}

function stop_pbench () {
  sudo "PATH=$PATH" sh -c pbench-kill-tools 
  sudo "PATH=$PATH" sh -c pbench-clear-tools
}

function start_pbench () {
  comupte_tools=(proc-sched_debug proc-interrupts sar openvswitch iostat)
  vm_tools=(proc-sched_debug proc-interrupts sar iostat)
 
  stop_pbench
  source ${stackrc} || error "can't load stackrc"
  echo "start tools on computes"
  for node in $(nova list | sed -n -r 's/.*compute.*ctlplane=([.0-9]+).*/\1/ p'); do
    for tool in ${comupte_tools[@]}; do
      sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=$node --name=$tool"
    done
  done

  echo "start tools on VMs"
  source ${overcloudrc} || error "can't load overcloudrc"
  for i in $(seq ${num_vm}); do
    for tool in ${vm_tools[@]}; do
      sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=demo$i --name=$tool"
    done
  done
}
 
 
SCRIPT_PATH=$(dirname $0)             # relative
SCRIPT_PATH=$(cd $SCRIPT_PATH && pwd)  # absolutized and normalized

echo "##### loading nfv_test.cfg"
if [ ! -f ${SCRIPT_PATH}/nfv_test.cfg ]; then
  error "nfv_test.cfg can't be found"
fi
source ${SCRIPT_PATH}/nfv_test.cfg

# this script can be called from browbeat
# browbeat env variable browbeat_nfv_vars to over write the cfg file variables
# example: browbeat_nfv_vars="x=a y=b z=c"
if [[ ! -z "${browbeat_nfv_vars}" ]]; then
  echo "##### loading browbeat_nfv_vars"
  for var_set_str in ${browbeat_nfv_vars}; do
    eval "${var_set_str}"
  done
fi

# when comparing string, ignore case
shopt -s nocasematch

# sanity check input parameters
echo "##### sanity check input parameters" 
check_input

# delete exisitng NFV instances and cleanup networks
echo "##### deleting existing nfv instances"
delete_nfv_instances

# if user-data is required for cloud-init, we need to build the mime first
echo "##### building user_data for cloud-init"
if [[ ! -z "${user_data}" ]]; then
  [ -f ${SCRIPT_PATH}/create_mime.py ] && [ -f ${SCRIPT_PATH}/post-boot.sh ] \
      && [ -f  ${SCRIPT_PATH}/cloud-config ] \
      || error "The following files are required: create_mime.py post-boot.sh cloud-config" 
  # make sure user_data is a absolute path
  [[ ${user_data} = /* ]] || user_data=${SCRIPT_PATH}/${user_data}
  ${SCRIPT_PATH}/create_mime.py ${SCRIPT_PATH}/cloud-config:text/cloud-config ${SCRIPT_PATH}/post-boot.sh:text/x-shellscript > ${user_data} || error "failed to create user-data for cloud-init"
fi

source ${overcloudrc} || error "can't load overcloudrc"

echo "##### building instance image"
if ! openstack image list | grep ${vm_image_name}; then
  #glance has no such an image listed, we need to upload it to glance
  #does the local image directory exists
  if [ ! -d ${nfv_tmp_dir} ]; then
    echo "directory ${nfv_tmp_dir} not exits, creating"
    mkdir -p ${nfv_tmp_dir} || error "failed to create ${nfv_tmp_dir}"
  fi

  #download image if it not exits on local directory
  vm_image_file="${nfv_tmp_dir}/${vm_image_file}"
  if [ -f ${vm_image_file} ]; then
    echo "found image ${vm_image_file}"
    # for existing cashed image we assume it is already processed
    fresh_image="false"
  else 
    echo "image ${vm_image_file} not found, fetching"
    # is the url pointing to local directory?
    if [[ "$vm_image_url" =~ ^https?: ]]; then
      wget $vm_image_url -O ${vm_image_file} || error "failed to download image"
    elif [[ -f $vm_image_url ]]; then
      cp $vm_image_url ${vm_image_file}
    else
      error "invalid url: $vm_image_url"
    fi
    fresh_image="true"
  fi

  # only process the image if it is fresh
  if [[ ${fresh_image} == "true" ]]; then
    #modify image to use persistent interface naming
    virt-edit -a ${vm_image_file} -e "s/net.ifnames=0/net.ifnames=1/g" /boot/grub2/grub.cfg || error "virt-edit failed"

    #assume vm dhco port is always ens3
    #it is ok the move fails in case this is not a new it was moved before
    virt-customize -a ${vm_image_file} --run-command "mv /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-ens3" 2>/dev/null
    #but if the following fail then we have to bail out
    virt-edit -a ${vm_image_file} -e "s/eth0/ens3/g" /etc/sysconfig/network-scripts/ifcfg-ens3 || error "virt-edit failed"
    # at this time, virt-cat and virt-ls can be used to doublecheck the change we made on the image

    # set up password for console logon, this can be done in cloud init as well
    virt-customize -a ${vm_image_file} --root-password password:password
    virt-customize -a ${vm_image_file} --password cloud-user:password
    virt-edit -a ${vm_image_file} -e "s/^UseDNS.*//g" /etc/ssh/sshd_config
    virt-customize -a ${vm_image_file} --run-command "echo 'UseDNS no' >> /etc/ssh/sshd_config"
      # need to have a way to pass root-keys to cloud-init 
    virt-customize -a ${vm_image_file} --upload /home/stack/.ssh/id_rsa.pub:/tmp/stack_key
    root_key=$(sudo cat /root/.ssh/id_rsa.pub)
    virt-customize -a ${vm_image_file} --write /tmp/root_key:"$root_key" 

    # we could disable cloud-init and only use ansible
    #virt-customize -a ${vm_image_file} --touch /etc/cloud/cloud-init.disabled

  fi
  # done with image process
  openstack image create --disk-format qcow2 --container-format bare   --public --file ${vm_image_file} ${vm_image_name} || error "failed to create image" 
fi

#update nova quota to allow more core use and more network
echo "##### updating project quota"
project_id=$(openstack project show -f value -c id admin)
nova quota-update --instances $num_vm $project_id
nova quota-update --cores $(( $num_vm * 6 )) $project_id
neutron quota-update --tenant_id $project_id --network $(( $num_vm + 2 ))
neutron quota-update --tenant_id $project_id --subnet $(( $num_vm + 2 ))

echo "##### adding keypair"
nova keypair-list | grep 'demo-key' || nova keypair-add --pub-key ~/.ssh/id_rsa.pub demo-key
openstack security group rule list | grep 22:22 || openstack security group rule create default --protocol tcp --dst-port 22:22 --src-ip 0.0.0.0/0
openstack security group rule list | grep icmp || openstack security group rule create default --protocol icmp

echo "##### deleting exisitng nfv flavor"
if openstack flavor list | grep nfv; then
  openstack flavor delete nfv
fi

# 6 vcpu to make sure the HT sibling not used by instance; an alternative, might be used hw:cpu_thread_policy=isolate, --vcpus 3 (rather than 6)
echo "##### creating nfv flavor"

openstack flavor create nfv --id 1 --ram 4096 --disk 20 --vcpus 6

# no need to set numa topo
#  nova flavor-key 1 set hw:cpu_policy=dedicated \
#                        hw:mem_page_size=1GB \
#                        hw:numa_nodes=1 \
#                        hw:numa_mempolicy=strict \
#                        hw:numa_cpus.0=0,1,2,3,4,5 \
#                        hw:numa_mem.0=4096

nova flavor-key 1 set hw:cpu_policy=dedicated \
                      hw:mem_page_size=1GB 
if [[ ${enable_HT} == "true" ]]; then
  nova flavor-key 1 set hw:cpu_thread_policy=require
fi

if [[ ${enable_multi_queue} == "true" ]]; then
  nova flavor-key 1 set vif_multiqueue_enabled=true
  openstack image set ${vm_image_name} --property hw_vif_multiqueue_enabled=true
fi

echo "##### creating instance access network"
if ! neutron net-list | grep access; then
  if [[ ${access_network_type} == "flat" ]]; then
    neutron net-create access --provider:network_type flat \
                              --provider:physical_network access \
                              --port_security_enabled=False
  else
    neutron net-create access --provider:network_type vlan \
                              --provider:physical_network access \
                              --provider:segmentation_id ${access_network_vlan} \
                              --port_security_enabled=False
  fi
  neutron subnet-create --name access --dns-nameserver ${dns_server} access 10.1.1.0/24
fi

echo "##### creating instance provider networks"
# the ooo templates is using sriov1/2 for data network; dpdk0/1.
for i in $(eval echo "{0..$num_vm}"); do
  if [[ ${provider_network_type} == "flat" ]]; then
    provider_opt="--provider:network_type flat"
  elif [[ ${provider_network_type} == "vlan" ]]; then
    provider_opt="--provider:network_type vlan \
                  --provider:segmentation_id $((data_vlan_start + i))"
  elif [[ ${provider_network_type} == "vxlan" ]]; then
    provider_opt="--provider:network_type vxlan \
                  --provider:segmentation_id $((data_vxlan_start + i))"
  else
    error "invalid provider_network_type: ${provider_network_type}"
  fi

  if [[ ${vnic_type} == "sriov" ]]; then
    neutron net-create provider-nfv$i ${provider_opt} \
                                      --provider:physical_network sriov$((i % 2 + 1)) \
                                      --port_security_enabled=False
  else 
    neutron net-create provider-nfv$i ${provider_opt} \
                                      --provider:physical_network dpdk$(($i % 2)) \
                                      --port_security_enabled=False
  fi
  neutron subnet-create --name provider-nfv$i \
                        --disable-dhcp \
                        --gateway 20.$i.0.1 \
                        provider-nfv$i 20.$i.0.0/16
done

declare -a vmState

if [[ ${vnic_type} == "sriov" ]]; then
  vnic_option="--vnic-type direct"
else
  vnic_option=""
fi

echo "##### starting instances"
for i in $(eval echo "{1..$num_vm}"); do
  provider1=$(openstack port create --network provider-nfv$((i - 1)) ${vnic_option} nfv$((i - 1))-port | awk '/ id/ {print $4}')
  provider2=$(openstack port create --network provider-nfv$i ${vnic_option} nfv$i-port | awk '/ id/ {print $4}')
  access=$(openstack port create --network access access-port-$i | awk '/ id/ {print $4}')
  # make sure port created complete before start the instance
  start_instance demo$i $provider1 $provider2 $access
  vmState[$i]=0
done

tmpfile=${SCRIPT_PATH}/tmpfile

echo "##### waiting for instances go live"
for n in {0..1000}; do
  sleep 2
  nova list > $tmpfile
  completed=1
  errored=0
  for i in $(eval echo "{1..$num_vm}"); do
    if [ ${vmState[$i]} -ne 1 ]; then
      if grep demo$i $tmpfile | egrep 'ACTIVE'; then
        vmState[$i]=1
      elif grep demo$i $tmpfile | egrep 'ERROR'; then
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
  error "failed to start all the instances"
fi


# update /etc/hosts entry with instances
echo "##### update /etc/hosts entry with instance names"
sudo sed -i -r '/vm/d' /etc/hosts
sudo sed -i -r '/demo/d' /etc/hosts
nova list | sudo sed -n -r 's/.*(demo[0-9]+).*access=([.0-9]+).*/\2 \1/p' | sudo tee --append /etc/hosts >/dev/null

# remove old entries in known_hosts
echo "##### remove old entries in known_hosts"
for i in $(seq $num_vm); do
  sudo sed -i -r "/demo$i/d" /root/.ssh/known_hosts
  sudo sed -i -r "/demo$i/d" /home/stack/.ssh/known_hosts
  vm_ip = $(grep demo$i /etc/hosts | awk '{print $1}')
  sudo sed -i -r "/${vm_ip}/d" /root/.ssh/known_hosts
  sudo sed -i -r "/${vm_ip}/d" /home/stack/.ssh/known_hosts
done

# record all VM's access info in ansible inventory file
nodes=${SCRIPT_PATH}/nodes

echo "##### record ansible hosts access info in $nodes"
echo "[VMs]" > $nodes 
nova list | sed -n -r 's/.*(demo[0-9]+).*access=([.0-9]+).*/\1 ansible_host=\2/ p' >> $nodes

cat <<EOF >>$nodes
[VMs:vars]
ansible_connection=ssh 
ansible_user=cloud-user
ansible_ssh_pass=redhat
ansible_become=true
EOF

source $stackrc || error "can't load stackrc"
echo "[computes]" >> $nodes
nova list | sed -n -r 's/.*compute.*ctlplane=([.0-9]+).*/\1/ p' >> $nodes
echo "[controllers]" >> $nodes
nova list | sed -n -r 's/.*control.*ctlplane=([.0-9]+).*/\1/ p' >> $nodes
cat <<EOF >>$nodes
[computes:vars]
ansible_connection=ssh
ansible_user=heat-admin
ansible_become=true
[controllers:vars]
ansible_connection=ssh
ansible_user=heat-admin
ansible_become=true
EOF

# give 60 sec to cloud-init to complete
if [[ ! -z "${user_data}" ]]; then
  sleep 60
fi

# check all VM are reachable by ping
# try 30 times
echo "##### testing instances access via ping"
for n in $(seq 30); do
  reachable=1
  for i in $(seq $num_vm); do
    ping -q -c5 demo$i || reachable=0
  done
  if [ $reachable -eq 1 ]; then
    break
  fi
  sleep 1
done      

[ $reachable -eq 1 ] || error "not all VM pingable"

# make sure remote ssh port is open
echo "##### testing instances access via ssh"
for n in $(seq 30); do
  reachable=1
  for i in $(seq $num_vm); do
     timeout 1 bash -c "cat < /dev/null > /dev/tcp/demo$i/22" || reachable=0
  done
  if [ $reachable -eq 1 ]; then
    break
  fi
  sleep 1
done

[ $reachable -eq 1 ] || error "not all VM ssh port open"


# upload ssh key to all $nodes. if cloud-init user-data is supplied, no need to update VMs 
echo "##### update authorized ssh key"
if [[ -z "${user_data}" ]]; then
  groups=(computes controllers VMs)
else
  groups=(computes controllers)
fi

for host in ${groups[@]}; do
  if [[ $host != "VMs" ]]; then
    clouduser=heat-admin
  else
    clouduser=cloud-user
  fi
  if [[ "$USER" == "stack" ]]; then
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m shell -a "> /root/.ssh/authorized_keys; echo $(sudo cat /home/stack/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys; echo $(sudo cat /root/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys"
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m lineinfile -a "name=/etc/ssh/sshd_config regexp='^UseDNS' line='UseDNS no'"
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m service -a "name=sshd state=restarted"
    ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m shell -a "echo $(sudo cat /root/.ssh/id_rsa.pub) >> /home/${clouduser}/.ssh/authorized_keys"
  else
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m shell -a "> /root/.ssh/authorized_keys; echo $(sudo cat /home/stack/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys; echo $(sudo cat /root/.ssh/id_rsa.pub) >> /root/.ssh/authorized_keys"
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m lineinfile -a "name=/etc/ssh/sshd_config regexp='^UseDNS' line='UseDNS no'"
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m service -a "name=sshd state=restarted"
    sudo -u stack ANSIBLE_HOST_KEY_CHECKING=False UserKnownHostsFile=/dev/null ansible $host -i $nodes -m shell -a "echo $(sudo cat /root/.ssh/id_rsa.pub) >> /home/${clouduser}/.ssh/authorized_keys"
  fi
done

echo "##### repin threads on compute nodes"
if [[ $vnic_type == "sriov" ]]; then
  ansible-playbook -i $nodes ${SCRIPT_PATH}/repin_threads.yml --extra-vars "repin_kvm_emulator=${repin_kvm_emulator}" || error "failed to repin thread"
else
  ansible-playbook -i $nodes ${SCRIPT_PATH}/repin_threads.yml --extra-vars "repin_ovs_nonpmd=${repin_ovs_nonpmd} repin_kvm_emulator=${repin_kvm_emulator} repin_ovs_pmd=${repin_ovs_pmd} pmd_vm_eth0=${pmd_vm_eth0} pmd_vm_eth1=${pmd_vm_eth1} pmd_vm_eth2=${pmd_vm_eth2} pmd_dpdk0=${pmd_dpdk0} pmd_dpdk1=${pmd_dpdk1} pmd_dpdk2=${pmd_dpdk2}" || error "failed to repin thread"
fi

# get mac address from pci slot number
echo "##### getting mac address from pci slot number"
get_mac_from_pci_slot ${traffic_gen_src_slot} traffic_src_mac
get_mac_from_pci_slot ${traffic_gen_dst_slot} traffic_dst_mac
echo traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac}

echo "##### provision nfv work load"
ansible-playbook -i $nodes ${SCRIPT_PATH}/nfv.yml --extra-vars "run_pbench=${run_pbench} traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac} routing=${routing} testpmd_fwd=${testpmd_fwd} num_vm=${num_vm}" || error "failed to run NFV application"


# running traffic
if [[ ${run_traffic_gen} == "true" ]]; then
  if [[ ${run_pbench} == "true" ]]; then
    echo "##### starting pbench agent"
    start_pbench
  fi

  source $overcloudrc
  mac1=`get_vm_mac demo1 provider-nfv0`
  mac2=`get_vm_mac demo${num_vm} provider-nfv${num_vm}`

  echo "##### starting traffic generator"
  opt_base="--config=${pbench_report_prefix} --samples=${samples} \
            --frame-sizes=${data_pkt_size} --num-flows=${num_flows} \
            --traffic-directions=${traffic_direction} \
            --flow-mods=src-ip --traffic-generator=${traffic_gen} \
            --devices=${traffic_gen_src_slot},${traffic_gen_dst_slot} \
            --search-runtime=${search_runtime} \
            --validation-runtime=${validation_runtime} \
            --max-loss-pct=${traffic_loss_pct} ${traffic_gen_extra_opt}"
  
  opt_mac="--dst-macs=$mac1,$mac2"
  opt_ip="--src-ips=20.0.255.254,20.${num_vm}.255.254 \
          --dst-ips=20.${num_vm}.255.254,20.0.255.254"
  
  opt_vlan="--vlan-ids=${data_vlan_start},$((data_vlan_start+num_vm))"
  # trex has issue with vlan traffic, here is a tempary workaround
  if [[ "$traffic_gen" == "trex-txrx" ]]; then
    opt_vlan=""
  fi
  
  if [[ $routing == "vpp" ]]; then
     if [[ ${provider_network_type} == "flat" ]]; then
       sudo "PATH=$PATH" sh -c "pbench-trafficgen \
            ${opt_base} ${opt_mac} ${opt_ip}" 
     elif [[ ${provider_network_type} == "vlan" ]]; then
       sudo "PATH=$PATH" sh -c "pbench-trafficgen \
            ${opt_base} ${opt_mac} ${opt_ip} ${opt_vlan}" 
     fi
  else
     if [[ ${testpmd_fwd} == "io" ]]; then
       opt_mac=""
     fi
  
     if [[ ${provider_network_type} == "flat" ]]; then
       sudo "PATH=$PATH" sh -c "pbench-trafficgen \
            ${opt_base} ${opt_mac}"
     elif [[ ${provider_network_type} == "vlan" ]]; then
       sudo "PATH=$PATH" sh -c "pbench-trafficgen \
            ${opt_base} ${opt_mac} ${opt_vlan}" 
     fi
  fi
  
  if [[ ${run_pbench} == "true" ]]; then
    # move the results to pbench server only if not run test from browbeat
    if [[ -z "${browbeat_nfv_vars}" ]]; then 
      sudo -i pbench-move-results
    fi
    if [[ ${stop_pbench_after} == "true" ]]; then
      stop_pbench
    fi
  fi
fi
  
if [[ ${cleanup} == "true" ]]; then
  echo "##### deleting nfv instances"
  delete_nfv_instances
fi
  
