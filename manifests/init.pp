#
# @summary Deploy watchdog service with specified kernel modules and parameters
#
# @example role_watchdog
#   class { 'role_watchdog':
#     type             => "best",
#     load_per_core_1m => 10,
#     min_mem_percent  => 10,
#     files_change      => [['/var/log/syslog', 300]],
#   }
#
# @param type
#  Type of watchdog to be used, one of auto/best/tco/soft/ipmi
#    * auto: Nothing is done and watchdog will just use the kernel module
#      that has been loaded automatically (if so)
#    * best: Will attempt to do a bit of magic, e.g: will blacklist Intel
#      TCO watchdog to make sure IPMI one is loaded is available or will
#      load softdog (software watchdog from Linux kernel if it thinks
#      nothing else is available)
#    * tco: Will use Intel TCO device which is built-in with most of Intel
#      CPU motherboards
#    * soft: Linux kernel soft watchdog, for machine not having any hardware
#      alternative
#    * ipmi: IPMI BMC oob watchdog
#
# @param load_per_core_1m
#  Max load (1 minute) (per CPU logical core) to trigger watchdog reboot
#
# @param load_per_core_5m
#  Max load (5 minutes) (per CPU logical core) to trigger watchdog reboot
#
# @param load_per_core_15m
#  Max load (15 minutes) (per CPU logical core) to trigger watchdog reboot
#
# @param min_mem_percent
#  Minimum allocatable memory (in percent 0-100) to trigger watchdog reboot
#  It will take care of converting this value in pages as expected by
#  watchdog daemon (will use allocatable-memory instead of meaningless
#  min-memory, needs a recent enough watchdog daemon, else ignored)
#
# @param files_change
#  List of two elements tuples representing file path and maximum seconds
#  without file change to trigger reboot
#
# @param watchdog_timeout
#  Number of seconds after reboot has been decided before the watchdog
#  devices reaches zero, some device may be limited, e.g: Raspberry Pi
#  embedded Broadcom SOC refuses values above 15
#
# @param repair_binary
#  Absolute path to a binary/scripts that can be used as a last attempt
#  to repair system before rebooting
#
# @param repair_timeout
#  Maximum number of seconds for the repair_binary to be run, 0 for unlimited
#
# @param repair_maximum
#  Number of attemps repair_binary can be called if it succeeded but the
#  initial error is still there (e.g: still not enough memory), 0 for
#  unlimited
#
# @param service_start
#  Start or stop service
#
# @param service_enable
#  Enable or disable service (register at boot), it could be a good option
#  to leave it to false while testing to avoid being stuck in a never ending
#  reboot loop
#
# @param override_pagesize
#  It seems on non X86 architectures, watchdog is buggy and does not detect
#  system page size correctly, I openeded a bug at Debian to see what people
#  think: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=975032
#  If such error occurs (be carefull on arm64), use this parameter to force
#  system pagefile to a different value (check watchdog daemon logs to see
#  what value it uses)
#


class role_watchdog (

  Enum['auto', 'best', 'tco', 'soft', 'ipmi'] $type = 'best',
  Optional[Integer[1]] $load_per_core_1m = undef,
  Optional[Integer[1]] $load_per_core_5m = undef,
  Optional[Integer[1]] $load_per_core_15m = undef,
  Optional[Integer[1, 100]] $min_mem_percent = undef,
  Optional[Array[Tuple[Stdlib::Absolutepath, Integer[1]]]] $files_change = undef,
  Integer[1] $watchdog_timeout = 300,
  Optional[Stdlib::Absolutepath] $repair_binary = undef,
  Optional[Integer[0]] $repair_timeout = undef,
  Optional[Integer[0]] $repair_maximum = undef,
  Boolean $service_start = false,
  Boolean $service_enable = false,
  Optional[Integer[1]] $override_pagesize = undef,

  ) {
  # Compute a bunch of variables to be compatible with both very old facts and new ones
  $has_path_fact = ($::facts != undef and $::facts['path'] != undef)
  $has_is_virtual_fact = ($::facts != undef and $::facts['is_virtual'] != undef)
  $has_architecture_fact = ($::facts != undef and $::facts['architecture'] != undef)
  $has_processors_facts = ($::facts != undef and $::facts['processors'] != undef)
  $has_processors_models_fact = ($has_processors_facts != undef and $::facts['processors']['models'] != undef)
  $has_processors_cores_fact = ($has_processors_facts != undef and $::facts['processors']['cores'] != undef)
  $has_memory_facts = ($::facts != undef and $::facts['memory'] != undef)
  $has_memory_system_facts = ($has_memory_facts != undef and $::facts['memory']['system'] != undef)
  $has_memory_system_total_bytes_fact = ($has_memory_system_facts != undef and $::facts['memory']['system']['total_bytes'] != undef)
  $has_os_family_fact = ($::facts != undef and $::facts['os'] != undef and $::facts['os']['family'] != undef)
  $has_os_hardware_fact = ($::facts != undef and $::facts['os'] != undef and $::facts['os']['hardware'] != undef)
  $has_os_release_facts = ($::facts != undef and $::facts['os'] != undef and $::facts['os']['release'] != undef)
  $os_family = $has_os_family_fact ? { false => $::osfamily, default => $::facts['os']['family'] }
  $os_hardware = $has_os_hardware_fact ? { false => $::osfamily, default => $::facts['os']['hardware'] }
  $os_distro_release_major = $has_os_release_facts ? { false => $::operatingsystemmajrelease, default => $facts['os']['release']['major'] }
  $path = $has_path_fact ? { false => $::path, default => $::facts['path'] }
  $is_virtual = $has_is_virtual_fact ? { false => $::is_virtual, default => $::facts['is_virtual'] }
  $architecture = $has_os_hardware_fact ? { false => $::hardwaremodel, default => $::facts['os']['hardware'] }
  $processor_0_model = $has_processors_models_fact ? { false => $::processor0, default => $::facts['processors']['models'][0] }
  $cores_count = $has_processors_cores_fact ? { false => $::processorcount, default => $::facts['processors']['cores'] }
  $memory_system_total_bytes = $has_memory_system_total_bytes_fact ? { false => $::memory['system']['total_bytes'], default => $::facts['memory']['system']['total_bytes'] }

  #fail("path=${path} is_virtual=${is_virtual} architecture=${architecture} ipmi_support=${ipmi_support} processor_0_model=${processor_0_model} cores_count=${cores_count} memory_system_total_bytes=${memory_system_total_bytes}")

  # Ensure dmidecode is preset, otherwise fact detecting IPMI support may fail
  if (!$is_virtual and $architecture in ['x86_64']) {
    ensure_packages('dmidecode')
  }

  # Install watchdog daemon
  ensure_packages('watchdog')

  # Configure kernel module to load/blacklist depending
  # on requested type of watchdog
  Exec { 'rmmod-intel-tco-watchdog':
    path        => $path,
    command     => 'rmmod iTCO_wdt',
    refreshonly => true,
  }
  # For RedHat only
  Exec { 'load-watchdog-module':
    path        => $path,
    command     => 'modprobe `cat /etc/modules-load.d/puppet-load-watchdog.conf`',
    refreshonly => true,
    notify      => Service['watchdog'],
  }

  case $type {

    'auto': {
    }

    'best': {
      # IPMI is supported !
      if ($ipmi_support) {
        # IPMI is supported and CPU is Intel => blacklist TCO
        if (downcase($processor_0_model) =~ /^intel/) {
          file { '/etc/modprobe.d/puppet-disable-intel-tco-watchdog.conf':
            content => "blacklist iTCO_wdt\n",
            notify  => Exec['rmmod-intel-tco-watchdog'],
          }
        } else {
          file { '/etc/modprobe.d/puppet-disable-intel-tco-watchdog.conf':
            ensure  => 'absent',
          }
        }
        $module_to_load = 'ipmi_watchdog'
      } else {
        if (!$is_virtual and downcase($processor_0_model) =~ /^intel/) {
          $module_to_load = 'iTCO_wdt'
        } else {
          $module_to_load = 'softdog'
        }
      }
    }

    'tco': {
      if ($is_virtual) {
        fail('Intel TCO watchdog is not supported on virtual machines')
      }
      if (downcase($processor_0_model) !~ /^intel/) {
        fail('Intel TCO watchdog is not supported on non-Intel machines')
      }
      $module_to_load = 'iTCO_wdt'
    }

    'soft': {
      if (!$is_virtual and downcase($processor_0_model) =~ /^intel/) {
        file { '/etc/modprobe.d/puppet-disable-intel-tco-watchdog.conf':
          content => "blacklist iTCO_wdt\n",
          notify  => Exec['rmmod-intel-tco-watchdog'],
        }
      }
      $module_to_load = 'softdog'
    }

    default: {
      fail("Unsupported selected type ${type}")
    }

  }

  # Disable watchdog in systemd (as usual systemd does what he want and
  # don't care about what has been asked... Seems the best way is to
  # point to a non-existing device but this option does not exist on
  # RedHat 7
  exec { 'systemd-daemon-reexec-after-changing-watchdog':
    path        => $path,
    command     => 'systemctl daemon-reexec',
    refreshonly => true,
  }
  exec { 'release-watchdog-from-systemd':
    path    => $path,
    command => "sed -i 's!^#*RuntimeWatchdogSec=.*$!RuntimeWatchdogSec=0!' /etc/systemd/system.conf",
    unless  => "grep -q '^RuntimeWatchdogSec=0$' /etc/systemd/system.conf",
    notify  => Exec['systemd-daemon-reexec-after-changing-watchdog'],
  }
  exec { 'release-watchdog-from-systemd-2':
    path    => $path,
    command => "sed -i 's!^#*WatchdogDevice=.*$!WatchdogDevice=/dev/non-existent-watchdog!' /etc/systemd/system.conf",
    unless  => "grep -q '^WatchdogDevice=/dev/non-existent-watchdog$' /etc/systemd/system.conf",
    onlyif  => "grep -q 'WatchdogDevice=' /etc/systemd/system.conf",
    notify  => Exec['systemd-daemon-reexec-after-changing-watchdog'],
  }

  # Deploy watchdog configuration and enable service
  case $os_family {

    'Debian': {
        # Kernel module to load
        file { '/etc/default/watchdog':
          content => template('role_watchdog/debian/default.erb'),
          require => Package['watchdog'],
          notify  => Service['watchdog'],
        }
    }

    'RedHat': {
        # Kernel module to load
        file { '/etc/modules-load.d/puppet-load-watchdog.conf':
          content => "${module_to_load}\n",
          notify  => Exec['load-watchdog-module'],
        }
    }

    default: {
      fail("Unsupported OS family \"${os_family}\", only Debian/RedHat supported")
    }

  }

  # Compute total memory in bytes
  if ($min_mem_percent) {
    $min_free_mem_bytes = Integer($memory_system_total_bytes * $min_mem_percent / 100)
    $min_free_pages = Integer($min_free_mem_bytes / $::default_page_size)
    if ($override_pagesize) {
      $min_free_pages = Integer($min_free_mem_bytes / $override_pagesize)
    } else {
      $min_free_pages = Integer($min_free_mem_bytes / $::default_page_size)
    }
  }

  # Main configuration file
  file { '/etc/watchdog.conf':
    content => template('role_watchdog/common/conf.erb'),
    require => Package['watchdog'],
    notify  => Service['watchdog'],
  }

  # Service
  service { 'watchdog':
    ensure => $service_start ? { true => 'running', default    => 'stopped' },
    enable => $service_enable,
  }

}
