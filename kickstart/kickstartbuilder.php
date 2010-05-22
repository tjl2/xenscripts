<?php
// kickstart-builder.php - display a kickstart file for a VM, based on GET vars
// This script needs to be placed on a PHP webserver and called with arguments
// to generate a kickstart file for you.

// GET vars:
// name = the Xen name of the VM
// distro = the Linux distro to use for the VM
// ver = the version of the distro
// arch = the architecture (e.g.: i386)
// ip = the IP address to configure the VM on
// nmask = the netmask for the VM
// gway = the network gateway
// hostname = the hostname to give the VM
// rootpw = the root password to give the VM - keep this alpha-numeric and change it after installation (you've jsut passed it over the web remember!)
// swap = the sixe to use for the swap partition (the rest of the disk space will be used by the / partition)
$filename = "{$_GET['name']}-ks.cfg";
$installation_server = ""; // the address of your PXE server
$installation_path = "{$_GET['distro']}/{$_GET['ver']}/{$_GET['arch']}";
$ip = $_GET['ip'];
$netmask = $_GET['nmask'];
$gateway = $_GET['gway'];
$hostname = $_GET['name'];
$nameservers = "8.8.8.8,8.8.4.4"; // a comma-separated list of nameservers for the VM to use in resolv.conf
$rootpw = crypt($_GET['rootpw'], '$1$vfsalt');
$swap_size = $_GET['swap'];

// If this is centos/rhel 4, the language specification is different.
if(($_GET['distro'] == 'rhel' || $_GET['distro'] == 'centos') && $_GET['ver'] == '4') {
  $lang = "lang en_US.UTF-8\nlangsupport --default=en_US.UTF-8 en_US.UTF-8";
}
else {
  $lang = "lang en_US.UTF-8";
}
// RHEL 5 has installation keys, which we need to skip.
if($_GET['distro'] == 'rhel') {
  $inst_key = "key --skip";
}
else {
  $inst_key = "";
}

// Assemble our ks file
$ks_out = "install
url --url http://$installation_server/$installation_path
$lang
network --device eth0 --bootproto static --ip $ip --netmask $netmask --gateway $gateway --nameserver $nameservers --hostname $hostname";
if($inst_key != '') {
  $ks_out .= "\n$inst_key";
}
$ks_out .= "
rootpw --iscrypted $rootpw
firewall --disabled
authconfig --enableshadow --enablemd5
selinux --disabled
timezone --utc Europe/London
bootloader --location=mbr --driveorder=xvda --append=\"console=xvc0\"
reboot

# Partitioning
clearpart --all --initlabel --drives=xvda,xvdb
part swap --size=$swap_size --ondisk=xvdb
part / --fstype ext3 --size=100 --grow --ondisk=xvda

%packages --nobase
@core
yum
openssh-server
wget

%post
mkdir -p /root/.ssh
chmod 0700 /root/.ssh
/usr/bin/wget http://pixie.1steasy.net/ks/authorized_keys -O /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys";
// Echo out our a kickstart info
header("Content-Type: text/plain");
echo $ks_out;
?>
