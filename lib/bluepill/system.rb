require 'etc'
require 'shellwords'
require 'english'

module Bluepill
  # This class represents the system that bluepill is running on.. It's mainly used to memoize
  # results of running ps auxx etc so that every watch in the every process will not result in a fork
  module System
    APPEND_MODE = 'a'

  module_function

    # The position of each field in ps output
    IDX_MAP = {
      pid: 0,
      ppid: 1,
      pcpu: 2,
      rss: 3,
      etime: 4,
      command: 5,
    }

    def pid_alive?(pid)
      ::Process.kill(0, pid)
      true
    rescue Errno::EPERM # no permission, but it is definitely alive
      true
    rescue Errno::ESRCH
      false
    end

    def cpu_usage(pid, include_children)
      ps = ps_axu
      return unless ps[pid]
      cpu_used = ps[pid][IDX_MAP[:pcpu]].to_f
      get_children(pid).each do |child_pid|
        cpu_used += ps[child_pid][IDX_MAP[:pcpu]].to_f if ps[child_pid]
      end if include_children
      cpu_used
    end

    def memory_usage(pid, include_children)
      ps = ps_axu
      return unless ps[pid]
      mem_used = ps[pid][IDX_MAP[:rss]].to_f
      get_children(pid).each do |child_pid|
        mem_used += ps[child_pid][IDX_MAP[:rss]].to_f if ps[child_pid]
      end if include_children
      mem_used
    end

    def running_time(pid)
      ps = ps_axu
      return unless ps[pid]
      parse_elapsed_time(ps[pid][IDX_MAP[:etime]])
    end

    def command(pid)
      ps = ps_axu
      return unless ps[pid]
      ps[pid][IDX_MAP[:command]]
    end

    def get_children(parent_pid)
      child_pids = []
      ps_axu.each_pair do |_pid, chunks|
        child_pids << chunks[IDX_MAP[:pid]].to_i if chunks[IDX_MAP[:ppid]].to_i == parent_pid.to_i
      end
      grand_children = child_pids.collect { |pid| get_children(pid) }.flatten
      child_pids.concat grand_children
    end

    # Returns the pid of the child that executes the cmd
    def daemonize(cmd, options = {})
      rd, wr = IO.pipe

      child = Daemonize.safefork
      if child
        # we don't want to create zombies, so detach ourselves from the child exit status
        ::Process.detach(child)

        # parent
        wr.close

        daemon_id = rd.read.to_i
        rd.close

        return daemon_id if daemon_id > 0
      else
        # child
        rd.close

        drop_privileges(options[:uid], options[:gid], options[:supplementary_groups])

        # if we cannot write the pid file as the provided user, err out
        exit unless can_write_pid_file(options[:pid_file], options[:logger])

        to_daemonize = lambda do
          # Setting end PWD env emulates bash behavior when dealing with symlinks
          Dir.chdir(ENV['PWD'] = options[:working_dir].to_s) if options[:working_dir]
          options[:environment].each { |key, value| ENV[key.to_s] = value.to_s } if options[:environment]

          redirect_io(*options.values_at(:stdin, :stdout, :stderr))

          ::Kernel.exec(*Shellwords.shellwords(cmd))
          exit
        end

        daemon_id = Daemonize.call_as_daemon(to_daemonize, nil, cmd)

        File.open(options[:pid_file], 'w') { |f| f.write(daemon_id) }

        wr.write daemon_id
        wr.close

        ::Process.exit!(true)
      end
    end

    def delete_if_exists(filename)
      tries = 0

      begin
        File.unlink(filename) if filename && File.exist?(filename)
      rescue IOError, Errno::ENOENT
      rescue Errno::EACCES
        retry if (tries += 1) < 3
        $stderr.puts("Warning: permission denied trying to delete #{filename}")
      end
    end

    # Returns the stdout, stderr and exit code of the cmd
    def execute_blocking(cmd, options = {})
      rd, wr = IO.pipe

      child = Daemonize.safefork
      if child
        # parent
        wr.close

        cmd_status = rd.read
        rd.close

        ::Process.waitpid(child)

        cmd_status.strip != '' ? Marshal.load(cmd_status) : {exit_code: 0, stdout: '', stderr: ''}
      else
        # child
        rd.close

        # create a child in which we can override the stdin, stdout and stderr
        cmd_out_read, cmd_out_write = IO.pipe
        cmd_err_read, cmd_err_write = IO.pipe

        pid = fork do
          begin
            # grandchild
            drop_privileges(options[:uid], options[:gid], options[:supplementary_groups])

            Dir.chdir(ENV['PWD'] = options[:working_dir].to_s) if options[:working_dir]
            options[:environment].each { |key, value| ENV[key.to_s] = value.to_s } if options[:environment]

            # close unused fds so ancestors wont hang. This line is the only reason we are not
            # using something like popen3. If this fd is not closed, the .read call on the parent
            # will never return because "wr" would still be open in the "exec"-ed cmd
            wr.close

            # we do not care about stdin of cmd
            STDIN.reopen('/dev/null')

            # point stdout of cmd to somewhere we can read
            cmd_out_read.close
            STDOUT.reopen(cmd_out_write)
            cmd_out_write.close

            # same thing for stderr
            cmd_err_read.close
            STDERR.reopen(cmd_err_write)
            cmd_err_write.close

            # finally, replace grandchild with cmd
            ::Kernel.exec(*Shellwords.shellwords(cmd))
          rescue => e
            (cmd_err_write.closed? ? STDERR : cmd_err_write).puts "Exception in grandchild: #{e}."
            (cmd_err_write.closed? ? STDERR : cmd_err_write).puts e.backtrace
            exit 1
          end
        end

        # we do not use these ends of the pipes in the child
        cmd_out_write.close
        cmd_err_write.close

        # wait for the cmd to finish executing and acknowledge it's death
        ::Process.waitpid(pid)

        # collect stdout, stderr and exitcode
        result = {
          stdout: cmd_out_read.read,
          stderr: cmd_err_read.read,
          exit_code: $CHILD_STATUS.exitstatus,
        }

        # We're done with these ends of the pipes as well
        cmd_out_read.close
        cmd_err_read.close

        # Time to tell the parent about what went down
        wr.write Marshal.dump(result)
        wr.close

        ::Process.exit!
      end
    end

    def store
      @store ||= {}
    end

    def reset_data
      store.clear unless store.empty?
    end

    def ps_axu
      # TODO: need a mutex here
      store[:ps_axu] ||= begin
        # BSD style ps invocation
        lines = `ps axo pid,ppid,pcpu,rss,etime,command`.split("\n")

        lines.each_with_object({}) do |line, mem|
          chunks = line.split(/\s+/)
          chunks.delete_if { |c| c.strip.empty? }
          pid = chunks[IDX_MAP[:pid]].strip.to_i
          command = chunks.slice!(IDX_MAP[:command], chunks.length).join ' '
          chunks[IDX_MAP[:command]] = command
          mem[pid] = chunks.flatten
        end
      end
    end

    def parse_elapsed_time(str)
      # [[dd-]hh:]mm:ss
      if str =~ /(?:(?:(\d+)-)?(\d\d):)?(\d\d):(\d\d)/
        days = (Regexp.last_match[1] || 0).to_i
        hours = (Regexp.last_match[2] || 0).to_i
        mins = Regexp.last_match[3].to_i
        secs = Regexp.last_match[4].to_i
        ((days * 24 + hours) * 60 + mins) * 60 + secs
      else
        0
      end
    end

    # be sure to call this from a fork otherwise it will modify the attributes
    # of the bluepill daemon
    def drop_privileges(uid, gid, supplementary_groups)
      return unless ::Process::Sys.geteuid.zero?
      uid_num = Etc.getpwnam(uid).uid if uid
      gid_num = Etc.getgrnam(gid).gid if gid
      supplementary_groups ||= []
      group_nums = supplementary_groups.collect do |group|
        Etc.getgrnam(group).gid
      end
      ::Process.groups = [gid_num] if gid
      ::Process.groups |= group_nums unless group_nums.empty?
      ::Process::Sys.setgid(gid_num) if gid
      ::Process::Sys.setuid(uid_num) if uid
      ENV['HOME'] = Etc.getpwuid(uid_num).try(:dir) || ENV['HOME'] if uid
    end

    def can_write_pid_file(pid_file, logger)
      FileUtils.touch(pid_file)
      File.unlink(pid_file)
      true
    rescue => e
      logger.warning(format('%s - %s', e.class.name, e.message))
      e.backtrace.each { |l| logger.warning l }
      false
    end

    def redirect_io(io_in, io_out, io_err)
      $stdin.reopen(io_in) if io_in

      if !io_out.nil? && !io_err.nil? && io_out == io_err
        $stdout.reopen(io_out, APPEND_MODE)
        $stderr.reopen($stdout)

      else
        $stdout.reopen(io_out, APPEND_MODE) if io_out
        $stderr.reopen(io_err, APPEND_MODE) if io_err
      end
    end
  end
end
