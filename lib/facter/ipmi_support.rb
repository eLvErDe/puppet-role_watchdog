Facter.add('ipmi_support') do
  setcode do
    if Facter.value(:is_virtual)
      false
    elsif not [ 'x86_64' ].include?(Facter.value(:hardwaremodel))
      false
    else
      Facter::Core::Execution.execute('dmidecode --type 38').match?('IPMI Device Information')
    end
  end
end
