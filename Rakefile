#!/usr/bin/env rake

require 'rake/testtask'

require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://docs.rubygems.org/read/chapter/20 for more options
  gem.name = "rubygems-yoink"
  gem.homepage = "http://github.com/yoink/rubygems-yoink"
  gem.license = "ASLv2"
  gem.summary = %Q{rubygems plugin which will allow a no-yank sync from a rubygems mirror}
  gem.description = %Q{rubygems plugin which will allow a no-yank sync from a rubygems mirror}
  gem.email = "davebenvenuti@gmail.com"
  gem.authors = ["Dave Benvenuti"]
  # dependencies defined in Gemfile
end
# Don't release to rubygems quite yet
# Jeweler::RubygemsDotOrgTasks.new


Rake::TestTask.new do |t|
  t.pattern = "test/**/*_test.rb"
  t.libs = ['lib', 'test']
end

task :default => [:test]

require_relative 'lib/yoink/tasks'
