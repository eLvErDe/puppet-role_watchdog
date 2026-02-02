Facter.add('ipmi_support') do
  confine :kernel => 'Linux'

  setcode do
    # Skip virtual machines
    if Facter.value(:is_virtual)
      false
    else
       # Determine hardware architecture (new → old)
      arch = if
        Facter.value(:os) && Facter.value(:os)['hardware']
          Facter.value(:os)['hardware']
        else
          Facter.value(:hardwaremodel)
        end
      # Only x86_64 systems support IPMI in this context
      if arch != 'x86_64'
        false
      else
        Facter::Core::Execution.execute('dmidecode --type 38').match?('IPMI Device Information')
      end
    end
  end

end
