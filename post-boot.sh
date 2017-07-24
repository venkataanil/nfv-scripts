#!/usr/bin/bash
set -x

# shutdown ssh access until we finish and reboot
systemctl stop sshd
sed -i -r -e'/^UseDNS.*/d' /etc/ssh/sshd_config
sed -i -e "\$aUseDNS no"  /etc/ssh/sshd_config

cat << EOF >  /etc/yum.repos.d/red-hat-enterprise-linux.repo
[red-hat-enterprise-linux]
name=red-hat-enterprise-linux
baseurl=http://pulp.dist.prod.ext.phx2.redhat.com/content/dist/rhel/server/7/7Server/x86_64/os/
enabled=1
gpgcheck=0
EOF

cat << EOF >  /etc/yum.repos.d/rhelosp-rhel-7-fast-datapth.repo
[rhelosp-rhel-7-fast-datapth]
name=rhelosp-rhel-7-fast-datapth
gpgcheck = 0
enabled = 1
baseurl = http://pulp.dist.prod.ext.phx2.redhat.com/content/dist/rhel/server/7/7Server/x86_64/fast-datapath/os/
EOF

cat << EOF >  /etc/yum.repos.d/rhel-7-common.repo
[rhel-7-common]
name=rhel-7-common
gpgcheck = 0
enabled = 1
baseurl = http://pulp.dist.prod.ext.phx2.redhat.com/content/dist/rhel/server/7/7Server/x86_64/rh-common/os/
EOF

cat << EOF >  /etc/yum.repos.d/rhel-optional.repo
[rhel73-optional]
name=rhel73-optional
baseurl=http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.3/Server-optional/x86_64/os/
enabled=1
gpgcheck=0
EOF

cat << EOF >  /etc/yum.repos.d/fdio.repo
[fdio-release]
name=fd.io release branch latest merge
baseurl=https://nexus.fd.io/content/repositories/fd.io.centos7/
enabled=1
gpgcheck=0
EOF

#yum remove -y tuned

yum install -y screen

yum install -y dpdk
yum install -y dpdk-tools

yum -y install libhugetlbfs-utils
hugeadm --create-global-mounts
grubby --update-kernel=`grubby --default-kernel` --args="default_hugepagesz=1G hugepagesz=1G hugepages=1 isolcpus=2-5"

#yum install -y tuned
yum install -y tuned-profiles-cpu-partitioning
sed -i -r '/^isolated_cores/d' /etc/tuned/cpu-partitioning-variables.conf
sed -i -e "\$aisolated_cores=2-5" /etc/tuned/cpu-partitioning-variables.conf
#systemctl enable tuned
#systemctl start tuned
#sleep 1
tuned-adm profile cpu-partitioning

yum -y install vpp

cat << EOF > /etc/vpp/startup.conf 
unix {
  nodaemon
  log /tmp/vpp.log
  full-coredump
}

cpu {
    #skip-cores 1
    main-core 0
    workers 2
    corelist-workers 2 4
}

dpdk {
    uio-driver uio_pci_generic
    socket-mem 1024

    dev 0000:00:05.0
    {
        num-rx-queues 1
        num-tx-queues 1
    }

    dev 0000:00:06.0
    {
        num-rx-queues 1
        num-tx-queues 1
    }

}

api-trace {
  on
}

api-segment {
  gid vpp
}
EOF

> /root/.ssh/authorized_keys
if [[ -f /tmp/stack_key ]]; then
  cat /tmp/stack_key > /root/.ssh/authorized_keys
fi
if [[ -f /tmp/root_key ]]; then
  cat /tmp/root_key >> /root/.ssh/authorized_keys
fi 
#sync
reboot

