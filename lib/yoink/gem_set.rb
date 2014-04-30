# Represents a set of gems as fetched by Gem::Mirror#update_specs (see rubygems-mirror)
# This is in desperate need of cleanup

require 'rubygems/mirror'
require 'redis'
require 'connection_pool'
require 'tempfile'
require 'thread'
require 'set'
require 'fog'
require 'json'

module Yoink

class GemSet

  attr_reader :gems
  attr_reader :yanked

  REDIS_GEMS_KEY = 'gems'
  REDIS_YANKED_KEY = 'yanked'

  REDIS_INCOMING_GEMS_KEY = 'gems-incoming'
  REDIS_INCOMING_YANKED_KEY = 'yanked-incoming'

  # Since we'll be operating in JRuby, let's make this thread safe
  @@singleton_semaphore = Mutex.new
  @@redis_semaphore = Mutex.new

  # Singleton access for the web app.  Clean this up when everything gets pulled out to stores
  def self.instance
    raise "set Yoink::GemSet.redis first" if redis_pool.nil?

    @@singleton_semaphore.synchronize do
      @@gemset = new if !defined?(@@gemset) || @@gemset.nil?
    end

    @@gemset
  end

  def self.redis_pool
    defined?(@@redis_pool) ? @@redis_pool : nil
  end

  def self.redis=(redis_client_or_pool, pool_size=9, timeout=5)
    @@redis_semaphore.synchronize do
      if redis_client_or_pool.nil?
        @@redis_pool = nil
      elsif redis_client_or_pool.is_a?(ConnectionPool)
        @@redis_pool = redis_client_or_pool
      else
        @@redis_pool = ConnectionPool.new(:size => pool_size, :timeout => timeout) { redis_client_or_pool }
      end
    end
  end

  def initialize(gem_list=nil, yanked=nil)
    @gems = gem_list.nil? ? nil : Set.new(gem_list)
    @yanked = yanked.nil? ? nil : Set.new(yanked)
  end

  def self.load_from_mirror(mirror_uri = Gem::Mirror::DEFAULT_URI)
    specs_tmp_path = Dir.mktmpdir

    mirror = Gem::Mirror.new mirror_uri, specs_tmp_path

    mirror.update_specs

    gems = Marshal.load(Gem.read_binary(File.join(specs_tmp_path, Gem::Mirror::SPECS_FILE)))

    new gems.collect { |tuple| [ tuple[0], tuple[1].to_s, tuple[2] ] }
  end

  def self.load_from_redis(include_yanked = true)
    new *(redis_pool.with do |redis_client| 
            [redis_client.smembers(REDIS_GEMS_KEY).collect{ |json| JSON.parse(json) }, (include_yanked ? redis_client.smembers(REDIS_YANKED_KEY).collect{ |json| JSON.parse(json) } : nil)]
          end)
  end

  # TODO need load_from_file(filename, yanked_filename)

  def save_to_redis(include_yanked = true)
    save_resource_to_redis :gems, REDIS_GEMS_KEY
    save_resource_to_redis :yanked, REDIS_YANKED_KEY if include_yanked
  end


  def save_to_file(filename, gzip=false)
    save_resource_to_file :gems, filename, gzip
  end

  def save_to_s3(bucketname, aws_access_key, aws_access_secret, filename, gzip=false)
    save_resource_to_s3 :gems, aws_access_key, aws_access_secret, bucketname, filename, gzip
  end

  def save_yanked_to_file(filename, gzip=false)
    save_resource_to_file :yanked, filename, gzip
  end

  def gem_exists?(gem_name, version, platform=Gem::Mirror::RUBY)
    if self.class.redis_pool
      gem_exists_in_redis? gem_name, version, platform
    else
      raise "set Yoink::GemSet.redis"
    end
  end


  def redis_merge!(new_gemset)
    # Store the new gemset in its entirety on its own.  This way we can see what was yanked
    new_gemset.save_resource_to_redis :gems, REDIS_INCOMING_GEMS_KEY
    
    # Then, add the new gemset to the existing gemset
    anything_changed = new_gemset.save_resource_to_redis :gems, REDIS_GEMS_KEY
    
    self.class.redis_pool.with do |redis|
      # Take the difference of the existing gemset and the new gemset, and put the results in a yanked set
      redis.sdiffstore REDIS_INCOMING_YANKED_KEY, REDIS_GEMS_KEY, REDIS_INCOMING_GEMS_KEY
      
      # Union the new yanked set with the existing yanked set, so we have every gem ever yanked
      redis.sunionstore REDIS_YANKED_KEY, REDIS_YANKED_KEY, REDIS_INCOMING_YANKED_KEY

      # Clean up
      redis.del REDIS_INCOMING_YANKED_KEY
      redis.del REDIS_INCOMING_GEMS_KEY
    end

    anything_changed
  end

  def gems
    verbose "fetching gems..." 
    @gems || self.class.redis_pool.with do |redis| 
      redis.sort(REDIS_GEMS_KEY, :order => 'alpha').collect { |json| JSON.parse(json) }
    end
  end

  def yanked
    @yanked || self.class.redis_pool.with do |redis| 
      redis.sort(REDIS_YANKED_KEY, :order => 'alpha').collect { |json| JSON.parse(json) }
    end
  end


  protected
  

  def gem_exists_in_redis?(gem_name, version, platform)
    self.class.redis_pool.with{ |redis| redis.sismember REDIS_GEMS_KEY, [ gem_name, version, platform ].to_json }
  end


  def save_resource_to_file(resource_name, filename, gzip)   
    storage = Fog::Storage.new(:provider => 'Local', :local_root => File.dirname(filename))
    directory = storage.directories.new(:key => '.')

    save_resource_to_fog_directory(directory, resource_name, File.basename(filename), gzip)
  end

  def save_resource_to_s3(resource_name, aws_access_key, aws_access_secret, bucketname, filename, gzip)
    storage = Fog::Storage.new(:provider => 'AWS', :aws_access_key_id => aws_access_key, :aws_secret_access_key => aws_access_secret)
    directory = storage.directories.new :key => bucketname

    save_resource_to_fog_directory(directory, resource_name, filename, gzip)
  end

  def save_resource_to_fog_directory(storage, resource_name, filename, gzip)
    to_marshal = send(resource_name).collect do |gem|
      verbose "processing #{gem}..."

      gem_name, version, platform = gem

      [gem_name, Gem::Version.new(version), platform]
    end


    verbose "writing to file/s3..."

    file = storage.files.new(:key => filename)

    if gzip
      file.body = Gem.gzip(Marshal.dump(to_marshal))
    else                
      file.body = Marshal.dump(to_marshal)
    end
    
    file.acl = 'public-read' if file.respond_to? :acl=
    file.save
    
  end

  def save_resource_to_redis(resource_name, redis_key)
    resource = self.send(resource_name)

    unless resource.empty?
      self.class.redis_pool.with do |redis_client| 
        to_write = resource.collect { |gem_tuple| gem_tuple.to_json.gsub(' ', '') }
        
        write_count = redis_client.sadd redis_key, to_write

        write_count != 0
      end
    end
  end

  def verbose(string)
    puts string if ENV['VERBOSE']
  end
end

end
