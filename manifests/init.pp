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

  ) {

  # Ensure dmidecode is preset, otherwise fact detecting IPMI support may fail
  if (!$::is_virtual and $::hardwaremodel in ['x86_64']) {
    ensure_packages('dmidecode')
  }

  # Install watchdog daemon
  ensure_packages('watchdog')

  # Configure kernel module to load/blacklist depending
  # on requested type of watchdog
  Exec { 'rmmod-intel-tco-watchdog':
    path        => $::path,
    command     => 'rmmod iTCO_wdt',
    refreshonly => true,
  }
  # For RedHat only
  Exec { 'load-watchdog-module':
    path        => $::path,
    command     => 'modprobe `cat /etc/modules-load.d/puppet-load-watchdog.conf`',
    refreshonly => true,
    notify      => Service['watchdog'],
  }

  case $type {

    'auto': {
    }

    'best': {
      # IPMI is supported !
      if ($::ipmi_support) {
        # IPMI is supported and CPU is Intel => blacklist TCO
        if (downcase($::processor0) =~ /^intel/) {
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
        if (!::is_virtual and downcase($::processor0) =~ /^intel/) {
          $module_to_load = 'iTCO_wdt'
        } else {
          $module_to_load = 'softdog'
        }
      }
    }

    'tco': {
      if ($::is_virtual) {
        fail('Intel TCO watchdog is not supported on virtual machines')
      }
      if (downcase($::processor0) !~ /^intel/) {
        fail('Intel TCO watchdog is not supported on non-Intel machines')
      }
      $module_to_load = 'iTCO_wdt'
    }

    'soft': {
      if (!::is_virtual and downcase($::processor0) =~ /^intel/) {
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
    path        => $::path,
    command     => 'systemctl daemon-reexec',
    refreshonly => true,
  }
  exec { 'release-watchdog-from-systemd':
    path    => $::path,
    command => "sed -i 's!^#*RuntimeWatchdogSec=.*$!RuntimeWatchdogSec=0!' /etc/systemd/system.conf",
    unless  => "grep -q '^RuntimeWatchdogSec=0$' /etc/systemd/system.conf",
    notify  => Exec['systemd-daemon-reexec-after-changing-watchdog'],
  }
  exec { 'release-watchdog-from-systemd-2':
    path    => $::path,
    command => "sed -i 's!^#*WatchdogDevice=.*$!WatchdogDevice=/dev/non-existent-watchdog!' /etc/systemd/system.conf",
    unless  => "grep -q '^WatchdogDevice=/dev/non-existent-watchdog$' /etc/systemd/system.conf",
    onlyif  => "grep -q 'WatchdogDevice=' /etc/systemd/system.conf",
    notify  => Exec['systemd-daemon-reexec-after-changing-watchdog'],
  }

  # Deploy watchdog configuration and enable service
  case $::osfamily {

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
      fail("Unsupported OS family ${::osfamily}, only Debian/RedHat supported")
    }

  }

  # Compute total memory in bytes
  if ($min_mem_percent) {
    $min_free_mem_bytes = Integer($::memory['system']['total_bytes'] * $min_mem_percent / 100)
    $min_free_pages = Integer($min_free_mem_bytes / $::default_page_size)
  }

  # Main configuration file
  file { '/etc/watchdog.conf':
    content => template('role_watchdog/common/conf.erb'),
    require => Package['watchdog'],
    notify  => Service['watchdog'],
  }

  # Service
  service { 'watchdog':
    ensure => 'running',
    enable => true,
  }

}
