require 'minitest/autorun'
require 'webmock'
require 'vcr'

require 'rubygems-yoink'

$test = true

VCR.configure do |c|
  c.cassette_library_dir = 'test/fixtures/vcr'
  c.hook_into :webmock
end

WebMock.disable_net_connect! :allow_localhost => true

if `which redis-server`.strip == ""
  $stderr.puts "\n\n\nredis-server not found.  Please install redis or add redis-server to your path\n\n\n"

  exit 1
end

TEST_ROOT = File.dirname(__FILE__)
TEST_REDIS_HOST = 'localhost'
TEST_REDIS_PORT = 16379


class MiniTest::Unit::TestCase

  def self.start_test_redis(flush = true)
    puts "starting test redis..."

    FileUtils.mkdir_p '/tmp/test-redis'
    `redis-server ./test/test-redis.conf`
  end

  def flush_test_redis
    # Wait for the redis server to actually start up
    retry_count = 0


    begin
      Redis.new(:host => TEST_REDIS_HOST, :port => TEST_REDIS_PORT).flushall 
    rescue Redis::CannotConnectError => e
      raise e if retry_count > 5
      
      # Try again
      retry_count += 1
      retry
    end
  end

  def self.stop_test_redis
    puts "stopping test redis..."

    termed = false
    
    loop do
      pid = `ps aux | grep redis-server | grep test-redis.conf | grep -v grep | awk '{print $2}'`
    
      if pid.strip != ''

        if termed
          # If we've already tried to send it a SIGTERM, drop the hammer this time
          Process.kill "KILL", pid.to_i
        else
          Process.kill "TERM", pid.to_i 
          
          termed = true
        end
      else
        break
      end

    end
  end

  def setup
    flush_test_redis
  end

  protected

  def with_vcr 
    VCR.use_cassette 'gem_set/test_can_load_from_mirror', :record => :once do
      yield 
    end
  end


end

MiniTest::Unit::TestCase.start_test_redis

MiniTest::Unit.after_tests do
  MiniTest::Unit::TestCase.stop_test_redis
end
