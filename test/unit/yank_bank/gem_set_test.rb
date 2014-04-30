require 'helper'
require 'fog'

class Yoink::GemSetTest < MiniTest::Unit::TestCase

  def setup
    super

    Yoink::GemSet.redis = Redis.new :host => TEST_REDIS_HOST, :port => TEST_REDIS_PORT
  end

  def test_can_load_from_mirror

    with_vcr do
      gemset = Yoink::GemSet.load_from_mirror

      assert_equal 271748, gemset.gems.size
      assert_equal ['_', '1.0', 'ruby'], gemset.gems.first
    end

  end


  def test_can_load_from_redis
    Yoink::GemSet.redis_pool.with { |redis| redis.sadd 'gems', ['foo', '1.0.1', 'ruby'].to_json.gsub(' ', '') }
    Yoink::GemSet.redis_pool.with { |redis| redis.sadd 'yanked', ['foo', '1.0.0', 'ruby'].to_json.gsub(' ', '') }

    gemset = Yoink::GemSet.load_from_redis

    assert_equal [ ['foo', '1.0.1', 'ruby'] ], gemset.gems.to_a
    assert_equal [ ['foo', '1.0.0', 'ruby'] ], gemset.yanked.to_a
  end

  def test_can_save_to_redis 
    gemset = Yoink::GemSet.new [ ['foo', '1.0.0', 'ruby'], ['bar', '0.0.1', 'ruby'] ]

    gemset.save_to_redis

    assert_equal [ ['foo', '1.0.0', 'ruby'], ['bar', '0.0.1', 'ruby'] ], (Yoink::GemSet.redis_pool.with do |redis| 
      redis.smembers('gems').collect{ |json| JSON.parse json }
    end)
  end

  def test_can_save_to_file
    tmpdir = Dir.tmpdir
    filename = File.join(tmpdir, 'specs')

    gemset = Yoink::GemSet.new [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_to_file filename

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                ]

    assert_equal expected_marshaled_object, Marshal.load(Gem.read_binary(filename))
  end

  def test_can_save_to_file_and_gzip
    tmpdir = Dir.tmpdir
    filename = File.join(tmpdir, 'specs')

    gemset = Yoink::GemSet.new [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_to_file filename, true

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                ]

    assert_equal expected_marshaled_object, Marshal.load(Gem.gunzip(Gem.read_binary(filename)))
    
  end

  def test_can_save_to_s3
    Fog.mock!
    s3 = Fog::Storage.new(:provider => 'AWS', :aws_access_key_id => 'access-key', :aws_secret_access_key => 'aws-secret')
    directory = s3.directories.new(:key => 'a-bucket')
    directory.save # create the bucket

    filename = '/specs'

    gemset = Yoink::GemSet.new [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_to_s3 'a-bucket', 'access-key', 'access-secret', filename

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                ]

    # Read from fog to a tmp file so we can read it to verify
    file = directory.files.get(filename)

    tempfile = Tempfile.new('specs')
    
    tempfile.write file.body
    tempfile.close

    assert_equal expected_marshaled_object, Marshal.load(Gem.read_binary(tempfile.path))
  ensure
    Fog::Mock.reset
    Fog.unmock!
  end

  def test_can_save_to_s3_and_gzip
    Fog.mock!
    s3 = Fog::Storage.new(:provider => 'AWS', :aws_access_key_id => 'access-key', :aws_secret_access_key => 'aws-secret')
    directory = s3.directories.new(:key => 'a-bucket')
    directory.save # create the bucket

    filename = '/specs.gz'

    gemset = Yoink::GemSet.new [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_to_s3 'a-bucket', 'access-key', 'access-secret', filename, true

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                ]

    # Read from fog to a tmp file so we can read it to verify
    file = directory.files.get(filename)

    tempfile = Tempfile.new('specs.gz')
    
    tempfile.write file.body
    tempfile.close

    assert_equal expected_marshaled_object, Marshal.load(Gem.gunzip(Gem.read_binary(tempfile.path)))

  ensure
    Fog::Mock.reset
    Fog.unmock!
  end


  def test_can_save_yanked_to_file
    tmpdir = Dir.tmpdir
    filename = File.join(tmpdir, 'yanked')

    gemset = Yoink::GemSet.new [], [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_yanked_to_file filename

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
    
                                ]

    assert_equal expected_marshaled_object, Marshal.load(Gem.read_binary(filename))
  end

  def test_can_parse_version_numbers_from_tricky_gem_names
    tricky_gems = [
                   ['omniauth-500-px', '0.1.0', 'ruby'], # has numbers and dashes before the version number
                   ['omniauth-500-px', '0.1.0', 'dotnet-1'], # not a real gem, but this one is extra tricky - it also has a platform
                  ]

    gemset = Yoink::GemSet.new tricky_gems
    tmpdir = Dir.tmpdir
    filename = File.join(tmpdir, 'tricky')
    
    gemset.save_to_file filename
    
    output = Marshal.load(Gem.read_binary(filename))

    assert_equal ['omniauth-500-px', Gem::Version.new('0.1.0'), 'ruby'], output[0]
    assert_equal ['omniauth-500-px', Gem::Version.new('0.1.0'), 'dotnet-1'], output[1]
  end

  def test_can_save_yanked_to_file_and_gzip
    tmpdir = Dir.tmpdir
    filename = File.join(tmpdir, 'yanked')

    gemset = Yoink::GemSet.new [], [ ['a-gem', '1.0.0', 'ruby'], ['another-gem', '1.0.1', 'universal-dotnet'] ]

    gemset.save_yanked_to_file filename

    expected_marshaled_object = [
                                 ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                 ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                ]

    assert_equal expected_marshaled_object, Marshal.load(Gem.read_binary(filename))
  end

  def test_singleton
    instance = Yoink::GemSet.instance
    assert_instance_of Yoink::GemSet, instance, "instance should be a Yoink::GemSet"
    assert (instance == Yoink::GemSet.instance), "instance should always return the same instance"
  end

  def test_singleton_requires_redis
    Yoink::GemSet.redis = nil

    exception = assert_raises(RuntimeError) do
      Yoink::GemSet.instance
    end

    assert_equal "set Yoink::GemSet.redis first", exception.message
  end

  def test_gem_exists    
    Yoink::GemSet.redis_pool.with { |redis| redis.sadd Yoink::GemSet::REDIS_GEMS_KEY, [ 'foo', '1.0.0', 'ruby' ].to_json }

    assert Yoink::GemSet.instance.gem_exists?('foo', '1.0.0'), 'foo-1.0.0 should exist'
    assert ! Yoink::GemSet.instance.gem_exists?('foo', '1.0.1'), 'foo-1.0.1 should not exist'
  end

  def test_can_set_redis_client
    redis_client = Redis.new :host => 'afakeredishost', :port => 12345
    Yoink::GemSet.redis = redis_client

    assert_instance_of ConnectionPool, Yoink::GemSet.redis_pool

    connection = Yoink::GemSet.redis_pool.checkout.instance_variable_get(:@client)
    assert_equal 'afakeredishost', connection.instance_variable_get(:@options)[:host]
    assert_equal 12345, connection.instance_variable_get(:@options)[:port]
  end

  def test_can_set_redis_connection_pool
    connection_pool = ConnectionPool.new :size => 1, :timeout => 5 do
      redis_client = Redis.new :host => TEST_REDIS_HOST, :port => TEST_REDIS_PORT
    end

    Yoink::GemSet.redis = connection_pool

    assert_equal connection_pool, Yoink::GemSet.redis_pool
  end

  def test_can_redis_merge
    gemset = Yoink::GemSet.new [ ['foo', '1.0.0', 'ruby'] ]

    gemset.save_to_redis

    new_gemset = Yoink::GemSet.new [ ['bar', '1.0.1', 'ruby'] ]

    gemset.redis_merge! new_gemset
 
    assert_equal [ ['bar', '1.0.1', 'ruby'], ['foo', '1.0.0', 'ruby'] ].collect(&:to_json), Yoink::GemSet.redis_pool.with { |redis| redis.smembers Yoink::GemSet::REDIS_GEMS_KEY }.sort
    
    assert_equal [ ['foo', '1.0.0', 'ruby'] ].collect(&:to_json), Yoink::GemSet.redis_pool.with { |redis| redis.smembers Yoink::GemSet::REDIS_YANKED_KEY }
  end

  def test_redis_merge_returns_true_if_anything_changed
    gemset = Yoink::GemSet.new [ ['foo', '1.0.0', 'ruby'] ]

    gemset.save_to_redis

    new_gemset = Yoink::GemSet.new [ ['bar', '1.0.1', 'ruby'], ['foo', '1.0.0', 'ruby'] ]

    assert_equal true, gemset.redis_merge!(new_gemset)    
  end

  def test_redis_merge_returns_false_if_nothing_changed
    gemset = Yoink::GemSet.new [ ['foo', '1.0.0', 'ruby'] ]

    gemset.save_to_redis

    new_gemset = Yoink::GemSet.new [ ['foo', '1.0.0', 'ruby'] ]

    assert_equal false, gemset.redis_merge!(new_gemset)
  end

end
