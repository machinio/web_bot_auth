# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Sign a GET request to crawltest.com and report the verification status"
task :crawltest do
  ruby "script/crawltest.rb"
end

task default: :test
