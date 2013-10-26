#!/bin/bash -ex
# vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4
#
# add_compute.sh - installs Nova compute on Ubuntu 12.04 LTS.
#

source setuprc

##############################################################################
## Install necessary packages
##############################################################################

aptitude update
aptitude install -y ubuntu-cloud-keyring
echo deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/havana main >> /etc/apt/sources.list

aptitude update
aptitude -y dist-upgrade
aptitude -y install \
    ntp \
    python-mysqldb \
    python-memcache \
    open-iscsi \
    open-iscsi-utils \
    bridge-utils \
    python-libvirt \
    python-cinderclient \
    nova-api \
    nova-compute \
    nova-compute-kvm \
    nova-network \
    python-keystoneclient

##############################################################################
## Disable IPv6
##############################################################################

echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf

##############################################################################
## Disable virbr0
##############################################################################

virsh net-autostart default --disable
virsh net-destroy default

##############################################################################
## Make a script to start/stop all services
##############################################################################

/bin/cat << EOF > openstack.sh
#!/bin/bash

NOVA="api compute network"

case "\$1" in
start|restart|status)
	for i in \$NOVA; do
		/sbin/\$1 nova-\$i
	done
	;;
stop)
	for i in \$NOVA; do
		/sbin/stop nova-\$i
	done
	;;
esac
exit 0
EOF
/bin/chmod u+x openstack.sh

##############################################################################
## Modify configuration files of Nova, Glance and Keystone
##############################################################################

CONF=/etc/nova/nova.conf
test -f $CONF.orig || cp $CONF $CONF.orig
/bin/cat << EOF > /etc/nova/nova.conf
[DEFAULT]
verbose=True
multi_host=True
allow_admin_api=True
api_paste_config=/etc/nova/api-paste.ini
instances_path=/var/lib/nova/instances
compute_driver=libvirt.LibvirtDriver
rootwrap_config=/etc/nova/rootwrap.conf
send_arp_for_ha=True
ec2_private_dns_show_ip=True
start_guests_on_host_boot=True
resume_guests_state_on_host_boot=True

# LOGGING
logdir=/var/log/nova
state_path=/var/lib/nova
lock_path=/var/lock/nova

# NETWORK
libvirt_use_virtio_for_bridges = True
firewall_driver=nova.virt.libvirt.firewall.IptablesFirewallDriver
dhcpbridge_flagfile=/etc/nova/nova.conf
dhcpbridge=/usr/bin/nova-dhcpbridge
public_interface=$PUBLIC_INTERFACE
# FlatDHCPManager
network_manager=nova.network.manager.FlatDHCPManager
flat_interface=$INTERNAL_INTERFACE
flat_network_bridge=br101
# VlanManager
#network_manager=nova.network.manager.VlanManager
#vlan_interface=$INTERNAL_INTERFACE
#vlan_start=101
fixed_range=$FIXED_RANGE
#flat_network_dhcp_start=
#network_size=255
force_dhcp_release = True
flat_injected=false
use_ipv6=false

# VNC
vncserver_proxyclient_address=\$my_ip
vncserver_listen=\$my_ip
keymap=en-us

#scheduler
scheduler_driver=nova.scheduler.filter_scheduler.FilterScheduler

# OBJECT
s3_host=$CONTROLLER_PUBLIC_ADDRESS
use_cow_images=yes

# GLANCE
image_service=nova.image.glance.GlanceImageService
glance_api_servers=$CONTROLLER_PUBLIC_ADDRESS:9292

# RABBIT
rabbit_host=$CONTROLLER_INTERNAL_ADDRESS
rabbit_virtual_host=/nova
rabbit_userid=nova
rabbit_password=$RABBIT_PASS

# DATABASE
sql_connection=mysql://openstack:$MYSQL_PASS@$CONTROLLER_INTERNAL_ADDRESS/nova

#use cinder
enabled_apis=ec2,osapi_compute,metadata
volume_api_class=nova.volume.cinder.API

#keystone
auth_strategy=keystone
keystone_ec2_url=http://$CONTROLLER_PUBLIC_ADDRESS:5000/v2.0/ec2tokens
EOF

CONF=/etc/nova/api-paste.ini
test -f $CONF.orig || cp $CONF $CONF.orig
sed -e "s/^auth_host *=.*/auth_host = $CONTROLLER_ADMIN_ADDRESS/" \
    -e 's/%SERVICE_TENANT_NAME%/service/' \
    -e 's/%SERVICE_USER%/nova/' \
    -e "s/%SERVICE_PASSWORD%/$ADMIN_PASSWORD/" \
    $CONF.orig > $CONF

chown -R nova /etc/nova

##############################################################################
## Start all srevices
##############################################################################

./openstack.sh start
sleep 5

##############################################################################
## Reboot
##############################################################################

echo Done
reboot
