require 'rubygems/command'
require 'yaml'
require 'rubygems-yoink'

#
# TODO (davebenvenuti 3/3/13) Perhaps we should move this to a filename that actually reflects its classname/modules
#

class Gem::Commands::SyncSpecsCommand < Gem::Command
  SUPPORTS_INFO_SIGNAL = Signal.list['INFO']

  def initialize
    super 'sync_specs', 'Sync specs from a Gem respository, preserving yanked gems.'
  end

  def description # :nodoc:
    <<-EOF
The sync_specs command uses the ~/.gem/.yoinkrc config file to pull the specs file from a RubyGems mirror, and merge it with a an existing spec, preserving yanked gems.

~/.gem/yoinkrc is a YAML document with the following format:

---
from: rubygems.org
redis: redis://localhost:6739/1
file: ~/specs.gz
s3: 
  bucket: a-bucket
  aws_access_key: aws-access-key
  aws_access_secret: aws-access-secret
  path: /specs.gz


The 'from' parameter is optional and will default to rubygems.org.  The 'redis' parameter is required and should be a redis url pointed at your Yoink redis endpoint.  The 'file' parameter is optional and if present, the task will write a marshalled, gzipped gem manifest similar to one you would download from rubygems.org.  The 's3' parameter is also optional, and needs to contain all relevant info to write the file to s3
    EOF
  end

  def execute
    parse_config

    Yoink::GemSet.redis = Redis.new :url => @redis_url

    puts "writing to redis @ #{@redis_url}..." unless $test
    gems_changed = Yoink::GemSet.instance.redis_merge! Yoink::GemSet.load_from_mirror(@from_mirror)

    if gems_changed
      unless @output_file.nil?
        puts "writing to file @ #{@output_file}..." unless $test
        Yoink::GemSet.instance.save_to_file @output_file, true
      end
      
      unless @s3.nil?
        puts "writing to s3..." unless $test
        Yoink::GemSet.instance.save_to_s3 @s3['bucket'], @s3['aws_access_key'], @s3['aws_access_secret'], @s3['path'], true
      end
    else
      puts "no gems changed.  not writing to file or s3" unless $test
    end
  end

  private

  def parse_config
    raise "Config file #{config_file} not found" unless File.exist? config_file

    config_yaml = YAML.load_file config_file

    @from_mirror = config_yaml['from'] || Gem::Mirror::DEFAULT_URI

    @redis_url = config_yaml['redis'] || ENV['REDIS_URL']

    raise "Config file #{config_file} is invalid - 'redis' required" if @redis_url.nil?

    @output_file = config_yaml['file'].nil? ? nil : File.expand_path(config_yaml['file'])

    @s3 = config_yaml['s3']
  end

  def config_file
    File.join Gem.user_home, '.gem', '.yoinkrc'
  end

end

