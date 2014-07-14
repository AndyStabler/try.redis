# encoding: utf-8

require_relative 'lib/shell_escape'
require_relative 'lib/redis_commands'

module NamespaceTools
   SYNTAX_ERROR = {error: "ERR Syntax error"}.freeze
   ARGUMENT_ERROR = -> cmd { {error: "ERR wrong number of arguments for '#{cmd}' command" } }

  # These are manually converted to integer output
  INTEGER_COMMANDS = %w[
    incr incrby decr decrby del ttl llen
    sadd zadd
    zremrangebyrank
    hincrby hdel
    lpush rpush lpushx rpushx lrem
    bitpos
    strlen
    pfadd pfcount
  ]

  # These commands return a nested array in ruby, need to be flattened
  FLATTEN_COMMANDS = %w[
    zrange zrevrange zrangebyscore zinterstore zunionstore
  ]

  def parse_command namespace, cmd, *args
    cmd = cmd.downcase

    if cmd == "keys"
      return { error: "KEYS is an expensive command. It needs to go through the whole database. Its use is not recommended (and thus disabled in try.redis)." }
    end

    command = ALL_COMMANDS[cmd.downcase]
    return nil unless command

    unless command.check_arity *args
      return ARGUMENT_ERROR[cmd]
    end

    keys = command.get_key_positions args
    keys.each { |i| args[i] and args[i] = "#{namespace}:#{args[i]}" }

    if cmd == "scan"
      i = 0
      found = false
      while i < args.size
        if args[i].downcase == "match"
          found = true
          args[i+1] = "#{namespace}:#{args[i+1]}"
          i += 2
          next
        end
        i += 1
      end

      args << "match" << "#{namespace}:*" unless found
    end

    [cmd, *args]
  end

  # Transform redis response from ruby to redis-cli like format
  #
  # @param input [String] The value returned from redis-rb
  # @param cmd [String] The command sent to redis
  # @param arg [String] Additional argument (used only for 'info' command to specify section)
  #
  # @return [String] redis-cli like formatted string of the input data
  def to_redis_output input, cmd=nil, arg=nil
    if cmd == 'info'
      return info_output(input, arg)
    end

    if cmd == 'ping' && input == 'PONG'
      return "PONG"
    end

    # Atleast hscan and zscan return nested arrays here.
    if ['scan', 'hscan', 'zscan', 'sscan'].include?(cmd)
      input[1].flatten!
    end

    case input
    when nil
      '(nil)'
    when 'OK'
      'OK'
    when true
      if cmd == 'set'
        return 'OK'
      else
        '(integer) 1'
      end
    when false
      if cmd == 'set'
        return '(nil)'
      else
        '(integer) 0'
      end
    when Array
      if input.empty?
        "(empty list or set)"
      else
        str = ""
        size = input.size.to_s.size
        input.each_with_index do |v, i|
          str << "#{(i+1).to_s.rjust(size)}) #{to_redis_output v}\n"
        end
        str
      end
    when Hash
      if input.empty?
        "(empty list or set)"
      else
        str = ""
        size = input.size.to_s.size
        i = 0
        input.each do |(k, v)|
          str << "#{(i+1).to_s.rjust(size)}) #{to_redis_output k}\n"
          str << "#{(i+2).to_s.rjust(size)}) #{to_redis_output v}\n"
          i += 2
        end
        str
      end
    when String, Numeric
      input.inspect
    else
      input
    end
  end

  INFO_SECTIONS = [
    ["Server", [ "redis_version", "redis_git_sha1", "redis_git_dirty",
                 "redis_build_id", "redis_mode", "os", "arch_bits",
                 "multiplexing_api", "gcc_version", "process_id", "run_id",
                 "tcp_port", "uptime_in_seconds", "uptime_in_days", "hz",
                 "lru_clock" ]
    ],
    ["Clients", [ "connected_clients", "client_longest_output_list",
                  "client_biggest_input_buf", "blocked_clients" ] ],
    ["Memory", [ "used_memory", "used_memory_human", "used_memory_rss",
                 "used_memory_peak", "used_memory_peak_human",
                 "used_memory_lua", "mem_fragmentation_ratio", "mem_allocator"
               ]
    ],
    ["Persistence", [ "loading", "rdb_changes_since_last_save",
                      "rdb_bgsave_in_progress", "rdb_last_save_time",
                      "rdb_last_bgsave_status", "rdb_last_bgsave_time_sec",
                      "rdb_current_bgsave_time_sec", "aof_enabled",
                      "aof_rewrite_in_progress", "aof_rewrite_scheduled",
                      "aof_last_rewrite_time_sec",
                      "aof_current_rewrite_time_sec", "aof_last_bgrewrite_status"
                    ]
    ],
    ["Stats", [ "total_connections_received", "total_commands_processed",
                "instantaneous_ops_per_sec", "rejected_connections",
                "sync_full", "sync_partial_ok", "sync_partial_err",
                "expired_keys", "evicted_keys", "keyspace_hits",
                "keyspace_misses", "pubsub_channels", "pubsub_patterns",
                "latest_fork_usec", "migrate_cached_sockets" ]
    ],
    ["Replication", [ "role", "connected_slaves", "master_repl_offset",
                      "repl_backlog_active", "repl_backlog_size",
                      "repl_backlog_first_byte_offset", "repl_backlog_histlen"
                    ]
    ],
    ["CPU", [ "used_cpu_sys", "used_cpu_user", "used_cpu_sys_children",
              "used_cpu_user_children" ]
    ],
    ["Cluster", [ "cluster_enabled" ] ],
    ["Keyspace", ["db0"] ]
  ]
  def info_output input, section=nil
    msg = ""

    # Show only data for subsection
    if section
      section_data = INFO_SECTIONS.find{|k,_| k.downcase == section }
      if section_data
        msg << "# #{section_data[0]}\n"
        section_data[1].each do |opt|
          msg << "#{opt}:#{input[opt]}\n" if input[opt]
        end
        msg << "\n"
      else
        msg = "\n\n"
      end

      return msg.chomp
    end

    INFO_SECTIONS.each do |section|
      msg << "# #{section[0]}\n"
      section[1].each do |opt|
        msg << "#{opt}:#{input[opt]}\n" if input[opt]
      end
      msg << "\n"
    end
    msg.chomp
  end

  class ThrottledCommand < Exception; end
  THROTTLED_COMMANDS = %w[ setbit setrange ]
  THROTTLE_MAX_OFFSET = 8_000_000 # 1 MB = 8000000 bits
  def throttle_commands argv
    if THROTTLED_COMMANDS.include?(argv[0]) && argv[2].to_i > THROTTLE_MAX_OFFSET
      raise ThrottledCommand, "This would result in a too big value. try.redis is only for testing so keep it small."
    end

    nil
  end

  include ShellEscape
end
