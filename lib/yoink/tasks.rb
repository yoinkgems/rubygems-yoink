namespace :yoink do

  desc 'Sync rubygems specs as configured in ~/.gem/.yoinkrc'

  task :sync_specs do
    $LOAD_PATH << File.expand_path(File.dirname(__FILE__) + '/..')

    require_relative '../rubygems-yoink'
    
    Gem::Commands::SyncSpecsCommand.new.execute
  end

end
