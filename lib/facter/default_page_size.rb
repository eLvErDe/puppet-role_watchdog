Facter.add('default_page_size') do
  confine :kernel => 'Linux'
  setcode do
    Facter::Core::Execution.execute('getconf PAGE_SIZE').to_i
  end
end
