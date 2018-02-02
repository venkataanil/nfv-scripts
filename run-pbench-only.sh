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

  if [ -z ${vm_vcpu_count+x} ]; then
    echo "vm_vcpu_count not set, default to: 6"
    vm_vcpu_count=6
  fi
  if (( vm_vcpu_count < 6 )); then
    error "vm_vcpu_count: ${vm_vcpu_count} invalid, needs at least 6"
  fi

  if [ -z ${enable_multi_queue+x} ]; then
    enable_multi_queue=false
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
  elif [[ ${provider_network_type} == "flat" ]]; then
    if [[ ${access_network_type} == "shared" ]]; then
      # sharing access and data network on the same port require vlan network type
      error "to use shared access_network_type, provider_network_type has to be vlan"
    fi
  else
    error "invalid provider_network_type: ${provider_network_type}"
  fi 

  if [[ ${access_network_type} == "vlan" || ${access_network_type} == "shared" ]]; then
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

  if [ -z ${stop_pbench_after+x} ]; then
    stop_pbench_after="false"
  fi
}

function stop_pbench () {
  sudo "PATH=$PATH" sh -c pbench-kill-tools 
  sudo "PATH=$PATH" sh -c pbench-clear-tools
}

function start_pbench () {
 
  stop_pbench
  source ${stackrc} || error "can't load stackrc"
  echo "start tools on computes"
  for node in $(nova list | sed -n -r 's/.*compute.*ctlplane=([.0-9]+).*/\1/ p'); do
    for tool in ${pbench_comupte_tools}; do
      sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=$node --name=$tool"
    done
    if [ "$ftrace_host" == "y" ]; then
    	sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=$node --name=ftrace -- --cpus=$pmd_vm_eth1,$pmd_vm_eth2,$pmd_dpdk0,$pmd_dpdk1,8,10"
    fi
  done

  echo "start tools on VMs"
  source ${overcloudrc} || error "can't load overcloudrc"
  for i in $(seq ${num_vm}); do
    for tool in ${pbench_vm_tools}; do
      sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=demo$i --name=$tool"
    done
    if [ "$ftrace_vm" == "y" ]; then
        sudo "PATH=$PATH" sh -c "pbench-register-tool --remote=$node --name=ftrace -- --cpus=2,4"
    fi
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

source ${SCRIPT_PATH}/core_util_functions

# sanity check input parameters
echo "##### sanity check input parameters" 
check_input

# get mac address from pci slot number
echo "##### getting mac address from pci slot number"
get_mac_from_pci_slot ${traffic_gen_src_slot} traffic_src_mac
get_mac_from_pci_slot ${traffic_gen_dst_slot} traffic_dst_mac
echo traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac}

vm_int_queues=$(echo ${pmd_dpdk1} | sed -e 's/,/ /g' | wc -w)
echo "##### provision nfv work load"
ansible-playbook -i $nodes ${SCRIPT_PATH}/nfv.yml --extra-vars "run_pbench=${run_pbench} traffic_src_mac=${traffic_src_mac} traffic_dst_mac=${traffic_dst_mac} routing=${routing} testpmd_fwd=${testpmd_fwd} num_vm=${num_vm} vm_vcpu_count=${vm_vcpu_count} mqueue=${enable_multi_queue} vm_int_queues=${vm_int_queues}" || error "failed to run NFV application"


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
  
