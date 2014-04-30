require 'helper'
require 'tempfile'
require 'rubygems'
require 'yoink/command'

class Yoink::CommandTest < MiniTest::Unit::TestCase

  def setup
    super

    Yoink::GemSet.redis = Redis.new :host => TEST_REDIS_HOST, :port => TEST_REDIS_PORT
  end
  
  def test_can_write_to_redis
    with_vcr do
      tmpfile_path = create_test_config 'redis' => "redis://#{TEST_REDIS_HOST}:#{TEST_REDIS_PORT}"

      command = Gem::Commands::SyncSpecsCommand.new 

      command.stub :config_file, tmpfile_path do
        command.execute
        
        assert_equal 271748, Yoink::GemSet.instance.gems.size              
      end
    end
  end

  def test_can_write_to_file
    specs_path = "#{Dir.tmpdir}/test-specs-#{Time.now.to_i}.gz"

    with_vcr do
      tmpfile_path = create_test_config 'redis' => "redis://#{TEST_REDIS_HOST}:#{TEST_REDIS_PORT}", 'file' => specs_path

      command = Gem::Commands::SyncSpecsCommand.new 

      command.stub :config_file, tmpfile_path do
        command.execute
        
        expected_marshaled_object = [
                                     ['a-gem', Gem::Version.new('1.0.0'), 'ruby'],
                                     ['another-gem', Gem::Version.new('1.0.1'), 'universal-dotnet']                      
                                     
                                    ]
        
        assert_equal 271748, Marshal.load(Gem.gunzip(Gem.read_binary(specs_path))).size
      end      
    end
  ensure
    File.delete specs_path rescue puts "couldn't delete #{specs_path}"
  end

  def test_can_write_to_s3
    Fog.mock!
    s3 = Fog::Storage.new(:provider => 'AWS', :aws_access_key_id => 'access-key', :aws_secret_access_key => 'aws-secret')
    directory = s3.directories.new(:key => 'a-bucket')
    directory.save # create the bucket

    with_vcr do
      tmpfile_path = create_test_config 'redis' => "redis://#{TEST_REDIS_HOST}:#{TEST_REDIS_PORT}", 's3' => { 'aws_access_key' => 'access-key', 'aws_access_secret' => 'access-secret', 'bucket' => 'a-bucket', 'path' => '/specs.gz' }

      command = Gem::Commands::SyncSpecsCommand.new 

      command.stub :config_file, tmpfile_path do
        command.execute
        
        file = directory.files.get('/specs.gz')

        assert file, "file should be present"
      end      
    end
    
  ensure
    Fog::Mock.reset
    Fog.unmock!
  end

  def test_wont_write_if_nothing_changed
    Fog.mock!
    s3 = Fog::Storage.new(:provider => 'AWS', :aws_access_key_id => 'access-key', :aws_secret_access_key => 'aws-secret')
    directory = s3.directories.new(:key => 'a-bucket')
    directory.save # create the bucket

    mock_incoming_gemset = MiniTest::Mock.new    
    
    mock_gemset_singleton = MiniTest::Mock.new
    mock_gemset_singleton.expect(:redis_merge!, false, [mock_incoming_gemset])
    
    
    Yoink::GemSet.stub(:instance, mock_gemset_singleton) do
      
      Yoink::GemSet.stub(:load_from_mirror, mock_incoming_gemset) do

        tmpfile_path = create_test_config 'redis' => "redis://#{TEST_REDIS_HOST}:#{TEST_REDIS_PORT}", 's3' => { 'aws_access_key' => 'access-key', 'aws_access_secret' => 'access-secret', 'bucket' => 'a-bucket', 'path' => '/specs.gz' }
        
        command = Gem::Commands::SyncSpecsCommand.new 
        
        command.stub :config_file, tmpfile_path do
          command.execute
          
          file = directory.files.get('/specs.gz')
          
          assert ! file, "file should not be present"
        end
   
      end
    end   
  
  ensure
    Fog::Mock.reset
    Fog.unmock!    
  end

  protected
  
  def create_test_config(config={})
    tmpfile = Tempfile.new('yoink_config')

    tmpfile.write config.to_yaml
    tmpfile.close

    tmpfile.path
  end

end
