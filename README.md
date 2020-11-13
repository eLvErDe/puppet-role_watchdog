# Puppet class to deploy Linux watchdog daemon

Features:
 * Type of watchdog selectable from enum, including "auto" (does nothing) and "best" that attempt to configure best watchdog available for your system (IPMI overs Intel TCO, fallback to SoftDog if no hardware available)
 * Load and blacklist kernel module to map /dev/watchdog to expected kernel module
 * Support both Debian and RedHat based systems
 * Watchdog.conf options configurable with sane class options
 * Smart configuration of allocatable-memory express in percentage of total RAM (conversion to pages is done by the code)
 * Disable systemd watchdog, so watchdog daemon can take over

Issues:
 * Will mostly fail to switch from one type of watchdog to another without rebooting (it is pretty hard to deactivate a watchdog kernel module already active)
 * Minimum allocatable memory will not work on RedHat/CentOS 7 or older (but will if you backport a more recent watchdog daemon)
