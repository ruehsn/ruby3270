# frozen_string_literal: true

# Startup scripts never outlive the app: stopping one ends everything it
# started, and so does the app ending, even abruptly.
#   ruby -Ilib test/process_job_test.rb
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "tn3270/process_job"

class ProcessJobTest < Minitest::Test
  RUBY = RbConfig.ruby
  LIB = File.expand_path("../lib", __dir__)
  # No shared console or pipes: a process that loses those may end by
  # itself, which would hide a process left running.
  QUIET = "in: File::NULL, out: File::NULL, err: File::NULL"

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def wait_for(seconds = 10)
    deadline = Time.now + seconds
    sleep 0.05 until yield || Time.now > deadline
    yield
  end

  def read_pid(file)
    wait_for { File.size?(file) }
    File.read(file).to_i
  end

  # A script that starts a program of its own, then waits a long time.
  def script_with_grandchild(dir)
    file = File.join(dir, "grandchild.pid")
    code = "pid = spawn(#{RUBY.inspect}, '-e', 'sleep 120', #{QUIET}); File.write(#{file.inspect}, pid.to_s); sleep 120"
    [code, file]
  end

  def test_stop_ends_the_script_and_what_it_started
    Dir.mktmpdir do |dir|
      code, file = script_with_grandchild(dir)
      opts = Tn3270::ProcessJob::WINDOWS ? {} : { pgroup: true }
      pid = spawn(RUBY, "-e", code, **opts)
      job = Tn3270::ProcessJob.new(pid)
      grandchild = read_pid(file)
      assert alive?(grandchild)
      job.stop
      Process.wait(pid)
      assert wait_for { !alive?(grandchild) }, "the script's own program kept running"
    end
  end

  def test_scripts_end_when_the_app_is_killed
    skip "job objects are Windows only" unless Tn3270::ProcessJob::WINDOWS

    Dir.mktmpdir do |dir|
      code, file = script_with_grandchild(dir)
      script_pid = File.join(dir, "script.pid")
      # Stands in for ruby3270: starts a script in a job, then dies without
      # any cleanup (like a crash or End Task).
      app = <<~RUBY
        require "tn3270/process_job"
        pid = spawn(#{RUBY.inspect}, "-e", #{code.inspect}, #{QUIET})
        job = Tn3270::ProcessJob.new(pid)
        abort "no job" unless job.contained?
        File.write(#{script_pid.inspect}, pid.to_s)
        sleep 0.1 until File.size?(#{file.inspect})
        exit!(0)
      RUBY
      app_pid = spawn(RUBY, "-I", LIB, "-e", app, in: File::NULL, out: File::NULL)
      Process.wait(app_pid)
      assert $?.success?, "the stand-in app failed"
      script = File.read(script_pid).to_i
      grandchild = File.read(file).to_i
      assert wait_for { !alive?(script) && !alive?(grandchild) }, "a script outlived the app"
    end
  end
end
