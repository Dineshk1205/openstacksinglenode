Openstack_Version='2023.1'
Openstack_VIP='172.90.0.201'
Internal_NIC_Name='ens192'
External_NIC_Name='ens224'

#Cloud network configuration 

IP_VERSION=${IP_VERSION:-4}
EXT_NET_CIDR='172.90.0.1/24'
EXT_NET_RANGE='start=172.90.0.210,end=172.90.0.245'
EXT_NET_GATEWAY='172.90.0.1'

#opentack all in one deployment

yum update -y
dnf install git python3-devel libffi-devel gcc openssl-devel python3-libselinux -y
dnf install python3-pip -y
pip3 install -U pip
pip install 'ansible-core>=2.13,<=2.14.2'
pip install 'ansible>=6,<8'
pip3 install git+https://opendev.org/openstack/kolla-ansible@stable/$Openstack_Version --ignore-installed requestes
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla
cp -r /usr/local/share/kolla-ansible/etc_examples/kolla/* /etc/kolla
cp /usr/local/share/kolla-ansible/ansible/inventory/* .
cd /etc/kolla
kolla-ansible install-deps
mkdir -p /etc/ansible
cat << EOF > /etc/ansible/ansible.cfg
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOF

kolla-genpwd
cp /usr/local/share/kolla-ansible/ansible/inventory/* .
pvcreate /dev/sdb /dev/sdc
vgcreate cinder-volumes /dev/sdb /dev/sdc
cd /etc/kolla
echo "kolla_internal_vip_address: "$Openstack_VIP"" >> globals.yml
echo "network_interface: "$Internal_NIC_Name"" >> globals.yml
echo "neutron_external_interface: "$External_NIC_Name"" >> globals.yml
echo "enable_cinder: "yes"" >> globals.yml >> globals.yml
echo "enable_cinder_backend_lvm: "yes""  >> globals.yml
echo "cinder_volume_group: "cinder-volumes"" >> globals.yml
echo "enable_cinder_backup: "no"" >> globals.yml
echo "nova_compute_virt_type: "qemu"" >> globals.yml
echo "enable_magnum: "yes"" >> globals.yml
echo "enable_cluster_user_trust: true" >> globals.yml
echo "enable_grafana: "yes"" >> globals.yml
echo "enable_prometheus: "yes"" >> globals.yml
echo "enable_skyline: "yes"" >> globals.yml
kolla-ansible -i all-in-one bootstrap-servers
kolla-ansible -i all-in-one prechecks
kolla-ansible -i all-in-one deploy
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/$Openstack_Version
kolla-ansible post-deploy
pip install python-magnumclient

#openstack configuration 
cd /etc/kolla
 . admin-openrc.sh
 openstack flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
 openstack flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
 openstack flavor create --id 3 --ram 4096 --disk 40 --vcpus 2 m1.medium
 openstack flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large
 openstack flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge
 
openstack network create --external --provider-physical-network physnet1 \
        --provider-network-type flat external

openstack subnet create --dhcp --ip-version ${IP_VERSION} \
        --allocation-pool $EXT_NET_RANGE --network external \
        --subnet-range $EXT_NET_CIDR --gateway $EXT_NET_GATEWAY external-subnet
        
if [ ! -f ~/.ssh/id_ecdsa.pub ]; then
    echo Generating ssh key.
    ssh-keygen -t ecdsa -N '' -f ~/.ssh/id_ecdsa
fi
if [ -r ~/.ssh/id_ecdsa.pub ]; then
    echo Configuring nova public key and quotas.
    openstack keypair create --public-key ~/.ssh/id_ecdsa.pub mykey
fi
        
wget https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/37.20230401.3.0/x86_64/fedora-coreos-37.20230401.3.0-openstack.x86_64.qcow2.xz

unxz fedora-coreos-37.20230401.3.0-openstack.x86_64.qcow2.xz

openstack image create Fedora-CoreOS-37 \
--public \
--disk-format=qcow2 \
--container-format=bare \
--property os_distro='fedora-coreos' \
--file=fedora-coreos-37.20230401.3.0-openstack.x86_64.qcow2


openstack coe cluster template create k8s-single-controller-37 \
--image Fedora-CoreOS-37 \
--keypair mykey \
--external-network external \
--dns-nameserver 8.8.8.8 \
--flavor m1.large \
--master-flavor m1.large \
--volume-driver cinder \
--docker-volume-size 40 \
--network-driver flannel \
--docker-storage-driver overlay2 \
--coe kubernetes 

openstack coe cluster create --cluster-template k8s-single-controller-37 --keypair mykey --master-count 1 --node-count 1 k8s-clu0


