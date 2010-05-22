require 'yaml'
require 'activesupport'
require 'fileutils'

class VirtualMachine
  # Read in our config (/etc/vmscripts/vmconf.yml)
  YAML_CONF = "/etc/vmscripts/vmconf.yml"
  vmconf = YAML.load_file(YAML_CONF)
  LOCAL_IMAGES_PATH = vmconf['paths']['local_images']
  HA_IMAGES_PATH = vmconf['paths']['ha_images']
  FDISK_INPUTS_PATH = vmconf['paths']['fdisk_inputs']
  XEN_CONFIG_DIR = vmconf['paths']['xen_configs']
  AUTHORIZED_KEYS_FILE = vmconf['paths']['authorized_keys']
  KS_SERVER = vmconf['kickstart']['server']
  KS_KERNEL_DIR = vmconf['kickstart']['bootimages']
  DEBIAN_MIRROR = vmconf['debootstrap_mirrors']['debian']
  UBUNTU_MIRROR = vmconf['debootstrap_mirrors']['ubuntu']
  NAMESERVERS = vmconf['nameservers']
  XEN_SERVERS = vmconf['xen_servers']
  NETWORKS = vmconf['networks']
  VMCREATE_EMAIL = vmconf['vmcreate_email']
  PACKAGES = vmconf['packages']
  DEFAULT_PACKAGE = vmconf['default_package']
  DISTROS = vmconf['distros']
  DEFAULT_DISTRO = vmconf['default_distro']
  DOMAIN = vmconf['domain']

  # Regular expressions to use when reading Xen config files:
  NAME_REGEX = /^\s*name\s*=/
  MEM_REGEX  = /^\s*maxmem\s*=/
  DISK_REGEX = /^\s*disk\s*=/
  VIF_REGEX  = /^\s*vif\s*=/
  SWAP_PATH_REGEX = /^(.)*-swap\.img$/
  VM_DISTRO_REGEX = /^# VM distro =/
  VM_HA_REGEX = /^# VM ha =/
  VM_PACKAGE_REGEX = /^# VM package =/

  attr_reader :rootpw, :network, :distro, :version, :arch, :package, :storage, :swap,
              :image_path, :swap_path, :ha, :mnt_path, :config_file

  def initialize(params)
    @name = params[:name] # add some checking to make sure this is unique
    @package = params[:package]
    @distro = params[:distro]
    @version = params[:version]
    @arch = params[:arch]
    @network = network_settings(params[:ip], params[:mac]) unless params[:ip].nil?
    unless params[:package].nil?
      @mem = mem_from_package(@package)
      @swap = swap_from_package(@package)
      @storage = params[:storage] ? params[:storage].to_i : storage_from_package(@package)
    end
    @rootpw = params[:rootpw] ? params[:rootpw] : random_pw
    @config_file = XEN_CONFIG_DIR + '/' + @name
    @ha = params[:ha] || false
    if params[:image_path]
      @image_path = params[:image_path]
    else
      @image_path = @ha ? "#{HA_IMAGES_PATH}/#{@name}.img" : "#{LOCAL_IMAGES_PATH}/#{@name}.img"
    end
    if params[:swap_path]
      @swap_path = params[:swap_path]
    else
      @swap_path = @ha ? "#{HA_IMAGES_PATH}/#{@name}-swap.img" : "#{LOCAL_IMAGES_PATH}/#{@name}-swap.img"
    end
    @mnt_path = "/mnt/#{@name}"
    @chroot = "/usr/sbin/chroot #{@mnt_path} /bin/bash -c"
    # We can put out debug info if we are given a :verbose param
    # This is used on some of our commands
    @verbose = params[:verbose] || false
  end
  
  def self.load_from_conf(conf_file, extra_params=nil)
    # Create a VirtualMachine object and set up based on settings in conf file.
    # This will contain just enough instance variables to work and some will be
    # left unset.
    @config_file = conf_file # We know this is our config_path
    params = {}
    File.open(@config_file, 'r') do |conf|
      while line = conf.gets
        # Parse each line
        case line
        when NAME_REGEX
          params[:name] = line.split[2].gsub(/["']/, '')
        when MEM_REGEX
          params[:mem] = line.split[2].gsub(/["']/, '')
        when DISK_REGEX
          line.split.each do |disk_tok|
            clean_tok = disk_tok.gsub(/[\[\]"']/, '').gsub(/,(.*)$/, '').gsub(/tap\:aio\:/, '').strip
            unless clean_tok =~ /^(disk|=)$/
              # We should now have image paths
              if clean_tok =~ /^.*-swap.img$/
                # This is our swap path
                params[:swap_path] = clean_tok
              else
                # This is our image path
                params[:image_path] = clean_tok
              end
            end
          end
        when VIF_REGEX
          line.split.each do |vif_tok|
            clean_tok = vif_tok.gsub(/[\[\]"']/, '').strip
            unless clean_tok =~ /^(vif|=)$/
              # We should now have a string such as mac=xxxx,ip=xxxx
              clean_tok.split(',').each do |tok|
                if tok =~ /^ip=/
                  # This is our IP address
                  params[:ip] = tok.gsub(/^ip=/, '')
                elsif tok =~ /^mac=/
                  # This is our MAC address
                  params[:mac] = tok.gsub(/^mac=/, '')
                end
              end
            end
          end
        when VM_DISTRO_REGEX
          # Assemble our distro-related parameters
          distro_str = line.split[-1].strip
          params[:distro]  = distro_str.split('-')[0]
          params[:version] = distro_str.split('-')[1]
          params[:arch]    = distro_str.split('-')[2]
        when VM_HA_REGEX
          # Get our HA parameter
          ha_str = line.split[-1].strip
          if ha_str =~ /^true$/
            params[:ha] = true
          elsif ha_str =~ /^false$/
            params[:ha] = false
          end
        when VM_PACKAGE_REGEX
          # Get our package parameter
          params[:package] = line.split[-1].strip
        end
      end
    end
    # Merge our params that we have read from config to any extra params we may
    # have been given
    params = params.merge(extra_params) if extra_params
    # Return a VirtualMachine object
    new params
  end

  def distro_string
    @distro + '-' + @version + '-' + @arch
  end

  def dd_img_file
    # Return the necessary 'dd' command to create image files
    storage_mb = (@storage * 1024).to_i
    if @ha
      puts "Creating sparse image file #{@image_path} of #{storage_mb}MB..." if @verbose
      "dd if=/dev/zero of=#{@image_path} oflag=direct bs=1M seek=#{storage_mb} count=1"
    else
      puts "Creating non-sparse image file #{@image_path} of #{storage_mb}MB..." if @verbose
      "dd if=/dev/zero of=#{@image_path} oflag=direct bs=1M count=#{storage_mb}"
    end
  end

  def dd_swap_img
    # Return the necessary 'dd' command to create swap image files
    if @ha
      puts "Creating sparse swap image file #{@swap_path} of #{@swap}MB..." if @verbose
      "dd if=/dev/zero of=#{@swap_path} oflag=direct bs=1M seek=#{@swap} count=1"
    else
      puts "Creating non-sparse swap image file #{@swap_path} of #{@swap}MB..." if @verbose
      "dd if=/dev/zero of=#{@swap_path} oflag=direct bs=1M count=#{@swap}"
    end
  end
  
  def mount_image
    # Mount the image file to @mnt_path and return the path
    # First, set up a loop device
    loop_device = `/sbin/losetup -f`.strip
    puts "Mounting file on loop device #{loop_device}..." if @verbose
    `/sbin/losetup #{loop_device} #{@image_path}`
    # Then map the partition with kpartx
    puts "Mapping partitions from mounted loop device..." if @verbose
    kpartx_out = `/sbin/kpartx -av #{loop_device}`
    device_map = "/dev/mapper/#{kpartx_out.split()[2]}"
    # Now mount it
    Dir.mkdir @mnt_path unless File.exist?(@mnt_path)
    puts "Mounting #{device_map} at #{@mnt_path}..." if @verbose
    `mount #{device_map} #{@mnt_path}`
    puts "#{@image_path} mounted at #{@mnt_path}" if @verbose
    @mnt_path
  end
  
  def unmount_image
    # Unmount the image and remove any device maps and loop devices
    puts "Unmounting #{@mnt_path}..." if @verbose
    `umount -f #{@mnt_path}`
    # Find out the loop device that our mount is related to
    # Our losetup -a command will return '/dev/loopX: [blah]:xxxxxx (/our/image/path/name.img)' 
    # so split and remove the ':' from token [0] to get our loop device
    loop_device = `/sbin/losetup -a | grep #{@image_path}`.split()[0].gsub(':', '')
    puts "Unmapping partitions from #{loop_device}..." if @verbose
    `/sbin/kpartx -d #{loop_device}`
    puts "Unmounting loop device #{loop_device}..." if @verbose
    `/sbin/losetup -d #{loop_device}`
    puts "#{@image_path} unmnounted." if @verbose
  end

  def is_running?
    `/usr/sbin/xm list #{@name} >> /dev/null 2>&1`
    if $?.exitstatus == 1 # if xm list cannot find @name, exitstatus is 1
      false
    else
      true
    end
  end

  def version_alias
    case @distro
    when 'debian'
      case @version
      when '4'
        'etch'
      when '5'
        'lenny'
      end
    when 'ubuntu'
      case @version
      when '8.04', '804'
        'hardy'
      when '8.10', '810'
        'intrepid'
      when '9.04', '904'
        'jaunty'
      end
    end
  end

  def debootstrap
    case @distro
    when 'debian'
      url = DEBIAN_MIRROR
      case @version
      when '4'
        packages = "--include=openssh-server,locales"
        packages += ',libc6-xen' if @arch == 'i386'
      when '5'
        packages = "--include=openssh-server,locales,udev"
      end
      command = "debootstrap --arch=#{@arch} #{packages} #{version_alias} #{@mnt_path} #{url}"
    when 'ubuntu'
      url = UBUNTU_MIRROR
      components = "--components=main,universe,multiverse"
      case @version
      when '804'
        packages = "--include=openssh-server"
        packages += ',libc6-xen' if @arch == 'i386'
      when '810', '904'
        packages = "--include=openssh-server"
        packages += ',libc6-xen' if @arch == 'i386'
      end
      command = "debootstrap --arch=#{@arch} #{packages} #{components} #{version_alias} #{@mnt_path} #{url}"
    end
    command
  end

  def post_debootstrap_commands
    # Call our relavant distro_ver_post_debootstrap method
    method("#{@distro}_#{@version}_post_debootstrap").call
  end

  def create_config_for_ks
    # Create a Xen config file that will e used to kick off a kickstart installation
    puts "Creating config file #{@config_file}..." if @verbose
    config = File.new(@config_file, 'w')
    config << "name = '#{@name}'\n"
    config << "maxmem = #{@mem}\nmemory = #{@mem}\n"
    config << "kernel = '#{KS_KERNEL_DIR}/#{@distro}/#{@version}/#{@arch}/vmlinuz'\n"
    config << "ramdisk = '#{KS_KERNEL_DIR}/#{@distro}/#{@version}/#{@arch}/initrd.img'\n"
    config << "extra = 'text ip=#{@network[:ip]} netmask=#{@network[:nmask]} "
    config << "gateway=#{@network[:gway]} dns=#{NAMESERVERS[0]} ks=#{kickstart_builder_url}'\n"
    config << "disk = ['tap:aio:#{@image_path},xvda,w', 'tap:aio:#{@swap_path},xvdb,w']\n"
    if @network[:type] == 'bridged'
      config << "vif = ['mac=#{@network[:mac]},bridge=xenbr0']\n"
    elsif @network[:type] == 'routed'
      config << "vif = ['mac=#{@network[:mac]},ip=#{@network[:ip]}']\n"
    end
    config << "on_poweroff = 'destroy'\non_reboot = 'destroy'\non_crash = 'destroy'\n"
    config.close
    if @verbose
      puts "Using the following xen conf file for our kickstart:"
      puts `cat #{@config_file}`
    end
  end
  
  def create_config
    # Create a Xen config file for the virtual machine
    puts "Creating config file #{@config_file}..." if @verbose
    config = File.new(@config_file, 'w')
    config << "name = '#{@name}'\n"
    config << "maxmem = #{@mem}\nmemory = #{@mem}\n"
    config << "bootloader = '/usr/bin/pygrub'\n"
    config << "disk = ['tap:aio:#{@image_path},xvda,w', 'tap:aio:#{@swap_path},xvdb,w']\n"
    if @network[:type] == 'bridged'
      config << "vif = ['mac=#{@network[:mac]},bridge=xenbr0']\n"
    elsif @network[:type] == 'routed'
      config << "vif = ['mac=#{@network[:mac]},ip=#{@network[:ip]}']\n"
    end
    config << "on_poweroff = 'destroy'\non_reboot = 'restart'\non_crash = 'restart'\n"
    # Add some of our own details as comments
    config << "## VM Script Details (DO NOT REMOVE) ##\n"
    config << "# VM distro = #{distro_string}\n"
    config << "# VM ha = #{@ha.to_s}\n"
    config << "# VM package = #{@package}\n"
    config.close
    if @verbose
      puts "Using the following xen conf file for our VM:"
      puts `cat #{@config_file}`
    end
  end

  def create_root_password
    puts "Setting root password..." if @verbose
    File.open("#{@mnt_path}/tmp/secret", 'w') do |secret|
      secret << "root:#{@rootpw}\n"
    end
    `#{@chroot} "/usr/sbin/chpasswd -m < /tmp/secret; rm -f /tmp/secret"`
  end

  private
  def network_settings(ip_address, mac_address=nil)
    # Retun a hash of network settings based on the IP we are given
    ip_network = ip_address.split('.')[0..2].join('.') # Grab the first 3 octets
    last_octet = ip_address.split('.')[-1].to_i # Grab the last octet as an integer
    NETWORKS.each do |net|
      if ip_network == net['network']
        if last_octet >= net['start'] and last_octet <= net['end']
          # Everything is OK with the IP we've been given
          # If we were supplied with a mac_address, use it, otherwise generate random
          mac = mac_address || random_mac
          network = {:ip => ip_address, :mac => mac, :nmask => net['nmask'],
                     :gway => net['gway'], :dns => NAMESERVERS,
                     :type => net['type']}
          return network
        else
          raise "IP address is outside the range of allowed IP addresses in #{YAML_CONF}"
        end
      end
    end
    # If we reach the end of this loop, this IP isn't in our config
    raise "IP address is not within any defined network in #{YAML_CONF}"
  end

  def random_mac
    # Xen MAC addresses need to start with 00:16:3e - we then create three
    # random hex numbers for the other three octets
    sprintf("00:16:3e:%02x:%02x:%02x", rand(0xff), rand(0xff), rand(0xff))
  end

  def kickstart_builder_url
    # Return the kickstartbuilder URL - this URL needs to be visited to create our kickstart file
    # (this only exists because a bug in virt-install will not allow ampersands in the ks arguments)
    url = "http://#{KS_SERVER}/ks/kickstartbuilder.php?name=#{@name}.#{DOMAIN}&" +
          "distro=#{@distro}&ver=#{@version}&arch=#{@arch}&ip=#{@network[:ip]}&" +
          "nmask=#{@network[:nmask]}&gway=#{@network[:gway]}&swap=#{@swap}&rootpw=#{@rootpw}"
  end

  def mem_from_package(package_name)
    # Return the memory size in MB for a package
    from_package(package_name, :mem)
  end

  def swap_from_package(package_name)
    # Return the swap size in MB for a package
    from_package(package_name, :swap)
  end

  def storage_from_package(package_name)
    # Return the storage size in GB for a package
    from_package(package_name, :storage)
  end

  def from_package(package_name, attribute)
    # Return the attribute for a specific package
    mem, swap, storage = nil, nil, nil
    PACKAGES.each do |package|
      if package['name'] == package_name
        mem = package['mem']
        swap = package['swap']
        storage = package['storage']
      end
    end
    # Now see what attribute we have been asked for and return that only.
    case attribute
    when :mem
      result = mem
    when :swap
      result = swap
    when :storage
      result = storage
    end
    if result.nil?
      raise "No attribute '#{attribute.to_s}' found for package '#{package_name}'"
    else
      result
    end
  end

  def random_pw
    passwd_length = 12
  	chars = ('a'..'z').to_a + ('0'..'9').to_a
  	chars -= %w(i o 0 1 l 0) # remove mistakeable chars
  	# Loop through passwd_length times, picking a random char
  	password = ''
  	passwd_length.times do
      # Decide if we should upcase
      upcase = rand 2
      if upcase > 0
        password += chars.rand.upcase
      else
        password += chars.rand
      end
  	end
  	password
  end

  def create_fstab
    # Write an fstab file in our vm filesystem (mounted at @mnt_path)
    puts "Creating a /etc/fstab file..." if @verbose
    File.open("#{@mnt_path}/etc/fstab", 'w') do |fstab|
      fstab << "proc\t\t/proc\tproc\tdefaults\t0 0\n"
      fstab << "/dev/xvda1\t/\text3\tdefaults\t0 1\n"
      fstab << "/dev/xvdb1\tnone\tswap\tdefaults\t0 0\n"
    end
  end
  
  def create_hosts
    # Write a hosts file in our vm filesystem (mounted at @mnt_path)
    puts "Creating a /etc/hosts file..." if @verbose
    File.open("#{@mnt_path}/etc/hosts", 'w') do |hosts|
      hosts << "127.0.0.1\tlocalhost.localdomain localhost\n"
      hosts << "#{@network[:ip]}\t#{@name}.#{DOMAIN} #{@name}\n"
    end
  end
  
  def create_hostname
    # Write a hostname file in our vm filesystem (mounted at @mnt_path)
    puts "Creating a /etc/hostname file..." if @verbose
    File.open("#{@mnt_path}/etc/hostname", 'w') do |hostname|
      hostname << "#{@name}"
    end
  end
  
  def create_network_interfaces
    # Write a /etc/network/interfaces file in our vm filesystem (mounted at @mnt_path)
    # This is specific to debian and derivitaves...
    puts "Creating a /etc/network/interfaces file..." if @verbose
    File.open("#{@mnt_path}/etc/network/interfaces", 'w') do |interfaces|
      interfaces << "auto lo\n"
      interfaces << "iface lo inet loopback\n"
      interfaces << "auto eth0\n"
      interfaces << "iface eth0 inet static\n"
      interfaces << " address #{@network[:ip]}\n"
      interfaces << " netmask #{@network[:nmask]}\n"
      interfaces << " gateway #{@network[:gway]}\n"
      interfaces << " dns-nameservers #{@network[:dns].join(' ')}\n"
    end
  end

  def create_timezone
    # Echo our local timezone to /etc/timezone
    puts "Creating a /etc/timezone file..." if @verbose
    File.open("#{@mnt_path}/etc/timezone", 'w') do |tz|
      tz << "Europe/London\n"
    end
  end

  def create_kernel_img_conf
    # apt-get installing a kernel will always ask questions, setup a /etc/kernel-img.conf
    # file to answer them
    puts "Creating a /etc/kernel-img.conf file (to answer kernel installation questions)..." if @verbose
    File.open("#{@mnt_path}/etc/kernel-img.conf", 'w') do |conf|
      conf << "# See kernel-img.conf(5) for details\n"
      conf << "do_symlinks = yes\n"
      conf << "relative_links = yes\n"
      conf << "do_bootloader = yes\n"
      conf << "do_bootfloppy = no\n"
      conf << "warn_initrd = no\n"
      conf << "link_in_boot = yes"
    end
  end

  def install_kernel
    # Our linux image package name depends on our arch
    if @distro == 'debian'
      if @arch == 'i386'
        linux_image = 'linux-image-xen-686'
      elsif @arch == 'amd64'
        linux_image = 'linux-image-xen-amd64'
      end
    elsif @distro == 'ubuntu'
      case version_alias
      when 'hardy'
        linux_image = 'linux-image-xen'
      when 'intrepid'
        linux_image = 'linux-image-server'
      when 'jaunty'
        linux_image = 'linux-image-virtual'
      end
    end
    # Install some packages using chroot
    puts "Chrooting and installing #{linux_image}..." if @verbose
    `#{@chroot} "mount -a; export LANG=C; apt-get update; apt-get -y --force-yes install #{linux_image}"`
  end

  def install_grub
    # We need a grub directory 
    puts "Creating grub directory..." if @verbose
    Dir.mkdir("#{@mnt_path}/boot/grub")
    # chroot and install grub
    puts "Chrooting and installing grub..." if @verbose
    `#{@chroot} "mount -a; export LANG=C; apt-get -y --force-yes install grub"`
  end
  
  def create_grub_menu(console=nil)
    # Write a grub menu.lst file in our vm filesystem (mounted at @mnt_path)
    # Find the filenames of our vmlinuz & initrd files and create our grub menu.lst
    puts "Figuring out our kernel and initrd names from /boot/..." if @verbose
    k = Dir.glob("#{@mnt_path}/boot/vmlinuz*")[0].split('/')[-1]
    i = Dir.glob("#{@mnt_path}/boot/initrd*")[0].split('/')[-1]
    puts "Creting grub menu.lst file..." if @verbose
    File.open("#{@mnt_path}/boot/grub/menu.lst", 'w') do |menu_lst|
      menu_lst << "default\t0\n"
      menu_lst << "title\tXen Kernel\n"
      menu_lst << "root\t(hd0,0)\n"
      menu_lst << "kernel\t/boot/#{k} root=/dev/xvda1 ro"
      if console.nil?
        menu_lst << "\n"
      else
        menu_lst << " console=#{console}\n"
      end
      menu_lst << "initrd\t/boot/#{i}\n"
    end
  end

  def add_apt_sources
    # The default debootstrap apt sources list does not contain update sources
    puts "Adding more sources to the /etc/apt/sources.list..." if @verbose
    File.open("#{@mnt_path}/etc/apt/sources.list", 'a') do |sources|
      if @distro == 'debian'
        sources << "\ndeb http://security.debian.org/ #{version_alias}/updates main\n"
        sources << "deb-src http://security.debian.org/ #{version_alias}/updates main\n"
      elsif @distro == 'ubuntu'
        sources << "deb http://security.ubuntu.com/ubuntu #{version_alias}-security main universe multiverse\n"
      end
    end
  end

  def disable_hwclock
    # We need to disable the hardware clock
    puts "Disabling the hardware clock scripts..." if @verbose
    hwc = "#{@mnt_path}/etc/init.d/hwclock.sh"
    File.chmod(0644, hwc) if File.exists?(hwc)
    hwcf = "#{@mnt_path}/etc/init.d/hwclockfirst.sh"
    File.chmod(0644, hwcf) if File.exists?(hwcf)
  end

  def create_dev
    # We need to create the /dev directory structure
    puts "Creating the /dev directory structure..." if @verbose
    if @distro == 'debian'
      `#{@chroot} "mount -a; cd /dev; ./MAKEDEV generic; ./MAKEDEV std"`
    elsif @distro == 'ubuntu'
      `#{@chroot} "mount -a; cd /dev; MAKEDEV generic;"`
    end
  end

  def set_locales
    # Generate the locales
    puts "Creating the /etc/locale.gen file..." if @verbose
    File.open("#{@mnt_path}/etc/locale.gen", 'w') do |locale_gen|
      locale_gen << "en_GB.UTF-8 UTF-8\n"
    end
    puts "Chrooting and generating locales..." if @verbose
    `#{@chroot} "/usr/sbin/locale-gen"`
  end

  def install_language_pack
    # Install language-pack-en - this is what is done in recent Ubuntu versions
    puts "Chrooting and installing the English language pack..." if @verbose
    `#{@chroot} "mount -a; export LANG=C; apt-get -y --force-yes install language-pack-en"`
  end
  
  def modify_securetty(console)
    # Add our Xen console to the /etc/securetty file
    puts "Appending #{console} to /etc/securetty file..." if @verbose
    File.open("#{@mnt_path}/etc/securetty", 'a') do |securetty|
      securetty << "#{console}\n"
    end
  end

  def modify_inittab(console)
    # Adjust the inittab to use our Xen console instead of tty1
    # Use a sed command, to save fucking about...
    puts "Modifying /etc/inittab to use #{console}..." if @verbose
    `sed -i -e 's/^\([2-6].*:respawn*\)/#\1/' -e 's/^T/#\t/' #{@mnt_path}/etc/inittab`
    `sed -i -e s/tty1/#{console}/ #{@mnt_path}/etc/inittab`
  end

  def create_event_d_console(console)
    # Recent Ubuntu versions use upstart, not Sys V init (no inittab to modify)
    puts "Creating /etc/event.d/#{console}..." if @verbose
    File.open("#{@mnt_path}/etc/event.d/#{console}", 'w') do |event_d|
      event_d << "# xvc0 - getty\n#\n# This service maintains a getty on xvc0 from the point the system is\n"
      event_d << "# started until it is shut down again.\n"
      event_d << "start on runlevel 2\nstart on runlevel 3"
      event_d << "start on runlevel 4\nstart on runlevel 5\n\n"
      event_d << "stop on runlevel 0\nstop on runlevel 1\nstop on runlevel 6\n\n"
      event_d << "respawn\nscript\n"
      event_d << "\tif [ ! -c /dev/xvc0 ]; then\n\t\tmknod --mode=600 /dev/xvc0 c 204 191;\n\tfi\n"
      event_d << "\texec /sbin/getty 38400 #{console}\n"
      event_d << "end script\n"
    end
  end

  def clean_apt
    # Remove all the apt-get cache files created during debootstrap
    puts "Chrooting and cleaning up apt to free space..." if @verbose
    `#{@chroot} "/usr/bin/apt-get clean"`
  end

  def setup_keys
    # Add our public keys to the server so we can log in
    puts "Setting up our SSH keys..." if @verbose
    Dir.mkdir("#{@mnt_path}/root/.ssh", 0700)
    # Our keys are available
    FileUtils.copy(AUTHORIZED_KEYS_FILE, "#{@mnt_path}/root/.ssh/authorized_keys")
    File.chmod(0600, "#{@mnt_path}/root/.ssh/authorized_keys")
  end

  def debian_4_post_debootstrap
    # There are some commands we need to run to get our debootstrapped system
    # configured....
    # Configure the fstab
    create_fstab
    # Configure the hosts file
    create_hosts
    # Configure the hostname file
    create_hostname
    # Configure the interfaces file
    create_network_interfaces
    # Append 'xvc0' to /etc/securetty
    modify_securetty 'xvc0'
    # Create our timezone 
    create_timezone
    # Update the apt sources list
    add_apt_sources
    # Create a /etc/kernel-img.conf
    create_kernel_img_conf
    # Install the kernel
    install_kernel
    # Install grub
    install_grub
    # Set our locales
    set_locales
    # Genereate a grub menu
    create_grub_menu 'xvc0'
    # Create a password for root
    create_root_password
    # Disable the hwclock
    disable_hwclock
    # Create the /dev/ files
    #create_dev - debian4 used to work before we did this!
    # Set up our SSH keys
    setup_keys
    # Finally, clean up the apt-get cache
    clean_apt
  end

  def debian_5_post_debootstrap
    # Configure the fstab
    create_fstab
    # Configure the hosts file
    create_hosts
    # Configure the hostname file
    create_hostname
    # Configure the interfaces file
    create_network_interfaces
    # Append 'hvc0' to /etc/securetty
    modify_securetty 'hvc0'
    # Update inittab to use hvc0
    modify_inittab 'hvc0'
    # Create our timezone 
    create_timezone
    # Create the /dev/ files
    create_dev
    # Update the apt sources list
    add_apt_sources
    # Create a /etc/kernel-img.conf
    create_kernel_img_conf
    # Install the kernel
    install_kernel
    # Install grub
    install_grub
    # Set our locales
    set_locales
    # Genereate a grub menu
    create_grub_menu 'hvc0'
    # Create a password for root
    create_root_password
    # Disable the hwclock
    disable_hwclock
    # Set up our SSH keys
    setup_keys
    # Finally, clean up the apt-get cache
    clean_apt
  end

  def ubuntu_804_post_debootstrap
    # Configure the fstab
    create_fstab
    # Configure the hosts file
    create_hosts
    # Configure the hostname file
    create_hostname
    # Configure the interfaces file
    create_network_interfaces
    # Create our timezone 
    create_timezone
    # Update the apt sources
    add_apt_sources
    # Create the /dev/ files
    create_dev
    # Create a /etc/kernel-img.conf
    create_kernel_img_conf
    # Install the kernel
    install_kernel
    # Install grub
    install_grub
    # Genereate a grub menu
    create_grub_menu 'xvc0'
    # Install an English language-pack
    install_language_pack
    # Create a password for root
    create_root_password
    # Disable the hwclock
    disable_hwclock
    # Set up an event.d console file
    create_event_d_console 'xvc0'
    # Set up our SSH keys
    setup_keys
    # Finally, clean up the apt-get cache
    clean_apt
  end
  
  def ubuntu_810_post_debootstrap
    # Configure the fstab
    create_fstab
    # Configure the hosts file
    create_hosts
    # Configure the hostname file
    create_hostname
    # Configure the interfaces file
    create_network_interfaces
    # Create our timezone 
    create_timezone
    # Update the apt sources
    add_apt_sources
    # Create the /dev/ files
    create_dev
    # Install grub
    install_grub
    # Create a /etc/kernel-img.conf
    create_kernel_img_conf
    # Install the kernel
    install_kernel
    # Genereate a grub menu
    create_grub_menu 'hvc0'
    # Install an English language-pack
    install_language_pack
    # Create a password for root
    create_root_password
    # Disable the hwclock
    disable_hwclock
    # Set up an event.d console file
    create_event_d_console 'hvc0'
    # Set up our SSH keys
    setup_keys
    # Finally, clean up the apt-get cache
    clean_apt
  end

  def ubuntu_904_post_debootstrap
    # Configure the fstab
    create_fstab
    # Configure the hosts file
    create_hosts
    # Configure the hostname file
    create_hostname
    # Configure the interfaces file
    create_network_interfaces
    # Create our timezone 
    create_timezone
    # Update the apt sources
    add_apt_sources
    # Create the /dev/ files
    create_dev
    # Install grub
    install_grub
    # Install the kernel
    install_kernel
    # Genereate a grub menu
    create_grub_menu 
    # Install an English language-pack
    install_language_pack
    # Create a password for root
    create_root_password
    # Disable the hwclock
    disable_hwclock
    # Set up an event.d console file
    #create_event_d_console 'xvc0'
    # Set up our SSH keys
    setup_keys
    # Finally, clean up the apt-get cache
    clean_apt
  end

end

class Array
  def random_choice
    self[rand(self.length)]
  end
end
