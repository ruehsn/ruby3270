# frozen_string_literal: true

require "rbconfig"

module Tn3270
  # Ties a child process, and everything it starts, to this program: stop
  # kills the whole tree, and when this program ends in any way (closed,
  # crashed, killed from Task Manager) Windows kills them too, so no engine
  # or startup script is left running on its own.
  #
  # Windows: a job object with "kill on job close"; the only handle to it is
  # ours, so it closes when this process ends. Elsewhere: the child leads its
  # own process group (spawn it with pgroup: true) and stop signals the group.
  class ProcessJob
    WINDOWS = RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)

    JOB_EXTENDED_LIMIT_INFORMATION = 9
    LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    EXTENDED_INFO_SIZE = 144 # JOBOBJECT_EXTENDED_LIMIT_INFORMATION on 64-bit
    LIMIT_FLAGS_OFFSET = 16
    PROCESS_SET_QUOTA = 0x0100
    PROCESS_TERMINATE = 0x0001

    def self.kernel
      @kernel ||= begin
        require "fiddle"
        k = Fiddle.dlopen("kernel32")
        p = Fiddle::TYPE_VOIDP
        i = Fiddle::TYPE_INT
        {
          create: Fiddle::Function.new(k["CreateJobObjectW"], [p, p], p),
          set_info: Fiddle::Function.new(k["SetInformationJobObject"], [p, i, p, i], i),
          open: Fiddle::Function.new(k["OpenProcess"], [i, i, i], p),
          assign: Fiddle::Function.new(k["AssignProcessToJobObject"], [p, p], i),
          terminate: Fiddle::Function.new(k["TerminateJobObject"], [p, i], i),
          close: Fiddle::Function.new(k["CloseHandle"], [p], i)
        }
      end
    end

    # Puts the process `pid` in a new job. Never raises: without a job the
    # process is still stopped by pid.
    def initialize(pid)
      @pid = pid
      @lock = Mutex.new
      @done = false
      @job = WINDOWS ? make_job(pid) : nil
    rescue StandardError # Fiddle::DLError included
      @job = nil
    end

    def contained? = !@job.nil?

    # Kills the process and everything it started.
    def stop
      @lock.synchronize do
        next if @done

        @done = true
        if @job
          self.class.kernel[:terminate].call(@job, 1)
          close_job
        elsif WINDOWS
          Process.kill("KILL", @pid)
        else
          Process.kill("TERM", -@pid) # the group the child leads
        end
      end
    rescue SystemCallError
      nil
    end

    # The process has ended: drop the job. Anything it left running in the
    # background goes with it.
    def release
      @lock.synchronize do
        @done = true
        close_job
      end
    end

    private

    def close_job
      self.class.kernel[:close].call(@job) if @job
      @job = nil
    end

    def make_job(pid)
      k = self.class.kernel
      job = k[:create].call(nil, nil)
      return nil if job.null?

      info = "\0" * EXTENDED_INFO_SIZE
      info[LIMIT_FLAGS_OFFSET, 4] = [LIMIT_KILL_ON_JOB_CLOSE].pack("L")
      process = k[:open].call(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid)
      ok = !process.null? &&
           k[:set_info].call(job, JOB_EXTENDED_LIMIT_INFORMATION, Fiddle::Pointer[info], EXTENDED_INFO_SIZE) != 0 &&
           k[:assign].call(job, process) != 0
      k[:close].call(process) unless process.null?
      return job if ok

      k[:close].call(job)
      nil
    end
  end
end
