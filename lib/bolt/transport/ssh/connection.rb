# frozen_string_literal: true

require 'logging'
require 'shellwords'
require 'bolt/node/errors'
require 'bolt/node/output'

module Bolt
  module Transport
    class SSH < Base
      class Connection
        class RemoteTempdir
          def initialize(node, path)
            @node = node
            @owner = node.user
            @path = path
            @logger = node.logger
          end

          def to_s
            @path
          end

          def chown(owner)
            return if owner.nil? || owner == @owner

            @owner = owner
            result = @node.execute(['chown', '-R', "#{@owner}:", @path], sudoable: true, run_as: 'root')
            if result.exit_code != 0
              message = "Could not change owner of '#{@path}' to #{@owner}: #{result.stderr.string}"
              raise Bolt::Node::FileError.new(message, 'CHOWN_ERROR')
            end
          end

          def delete
            result = @node.execute(['rm', '-rf', @path], sudoable: true, run_as: @owner)
            if result.exit_code != 0
              @logger.warn("Failed to clean up tempdir '#{@path}': #{result.stderr.string}")
            end
          end
        end

        attr_reader :logger, :user, :target
        attr_writer :run_as

        def initialize(target)
          @target = target

          @user = @target.user || Net::SSH::Config.for(target.host)[:user] || Etc.getlogin
          @run_as = nil

          @logger = Logging.logger[@target.host]
        end

        if !!File::ALT_SEPARATOR
          require 'ffi'
          module Win
            extend FFI::Library
            ffi_lib 'user32'
            ffi_convention :stdcall
            attach_function :FindWindow, :FindWindowW, %i[buffer_in buffer_in], :int
          end
        end

        def connect
          transport_logger = Logging.logger[Net::SSH]
          transport_logger.level = :warn
          options = {
            logger: transport_logger,
            non_interactive: true
          }

          if (key = target.options['private-key'])
            if key.instance_of?(String)
              options[:keys] = key
            else
              options[:key_data] = [key['key-data']]
            end
          end

          options[:port] = target.port if target.port
          options[:password] = target.password if target.password
          options[:verify_host_key] = if target.options['host-key-check']
                                        Net::SSH::Verifiers::Secure.new
                                      else
                                        Net::SSH::Verifiers::Lenient.new
                                      end
          options[:timeout] = target.options['connect-timeout'] if target.options['connect-timeout']

          # Mirroring:
          # https://github.com/net-ssh/net-ssh/blob/master/lib/net/ssh/authentication/agent.rb#L80
          # https://github.com/net-ssh/net-ssh/blob/master/lib/net/ssh/authentication/pageant.rb#L403
          if defined?(UNIXSocket) && UNIXSocket
            if ENV['SSH_AUTH_SOCK'].to_s.empty?
              @logger.debug { "Disabling use_agent in net-ssh: ssh-agent is not available" }
              options[:use_agent] = false
            end
          elsif !!File::ALT_SEPARATOR
            pageant_wide = 'Pageant'.encode('UTF-16LE')
            if Win.FindWindow(pageant_wide, pageant_wide).to_i == 0
              @logger.debug { "Disabling use_agent in net-ssh: pageant process not running" }
              options[:use_agent] = false
            end
          end

          @session = Net::SSH.start(target.host, @user, options)
          @logger.debug { "Opened session" }
        rescue Net::SSH::AuthenticationFailed => e
          raise Bolt::Node::ConnectError.new(
            e.message,
            'AUTH_ERROR'
          )
        rescue Net::SSH::HostKeyError => e
          raise Bolt::Node::ConnectError.new(
            "Host key verification failed for #{target.uri}: #{e.message}",
            'HOST_KEY_ERROR'
          )
        rescue Net::SSH::ConnectionTimeout
          raise Bolt::Node::ConnectError.new(
            "Timeout after #{target.options['connect-timeout']} seconds connecting to #{target.uri}",
            'CONNECT_ERROR'
          )
        rescue StandardError => e
          raise Bolt::Node::ConnectError.new(
            "Failed to connect to #{target.uri}: #{e.message}",
            'CONNECT_ERROR'
          )
        end

        def disconnect
          if @session && !@session.closed?
            @session.close
            @logger.debug { "Closed session" }
          end
        end

        # This method allows the @run_as variable to be used as a per-operation
        # override for the user to run as. When @run_as is unset, the user
        # specified on the target will be used.
        def run_as
          @run_as || target.options['run-as']
        end

        # Run as the specified user for the duration of the block.
        def running_as(user)
          @run_as = user
          yield
        ensure
          @run_as = nil
        end

        def sudo_prompt
          '[sudo] Bolt needs to run as another user, password: '
        end

        def handled_sudo(channel, data)
          if data.lines.include?(sudo_prompt)
            if target.options['sudo-password']
              channel.send_data "#{target.options['sudo-password']}\n"
              channel.wait
              return true
            else
              raise Bolt::Node::EscalateError.new(
                "Sudo password for user #{@user} was not provided for #{target.uri}",
                'NO_PASSWORD'
              )
            end
          elsif data =~ /^#{@user} is not in the sudoers file\./
            @logger.debug { data }
            raise Bolt::Node::EscalateError.new(
              "User #{@user} does not have sudo permission on #{target.uri}",
              'SUDO_DENIED'
            )
          elsif data =~ /^Sorry, try again\./
            @logger.debug { data }
            raise Bolt::Node::EscalateError.new(
              "Sudo password for user #{@user} not recognized on #{target.uri}",
              'BAD_PASSWORD'
            )
          end
          false
        end

        def execute(command, sudoable: false, **options)
          result_output = Bolt::Node::Output.new
          run_as = options[:run_as] || self.run_as
          use_sudo = sudoable && run_as && @user != run_as

          command_str = command.is_a?(String) ? command : Shellwords.shelljoin(command)
          if use_sudo
            sudo_str = Shellwords.shelljoin(["sudo", "-S", "-u", run_as, "-p", sudo_prompt])
            command_str = "#{sudo_str} #{command_str}"
          end

          # Including the environment declarations in the shelljoin will escape
          # the = sign, so we have to handle them separately.
          if options[:environment]
            env_decls = options[:environment].map do |env, val|
              "#{env}=#{Shellwords.shellescape(val)}"
            end
            command_str = "#{env_decls.join(' ')} #{command_str}"
          end

          @logger.debug { "Executing: #{command_str}" }

          session_channel = @session.open_channel do |channel|
            # Request a pseudo tty
            channel.request_pty if target.options['tty']

            channel.exec(command_str) do |_, success|
              unless success
                raise Bolt::Node::ConnectError.new(
                  "Could not execute command: #{command_str.inspect}",
                  'EXEC_ERROR'
                )
              end

              channel.on_data do |_, data|
                unless use_sudo && handled_sudo(channel, data)
                  result_output.stdout << data
                end
                @logger.debug { "stdout: #{data}" }
              end

              channel.on_extended_data do |_, _, data|
                unless use_sudo && handled_sudo(channel, data)
                  result_output.stderr << data
                end
                @logger.debug { "stderr: #{data}" }
              end

              channel.on_request("exit-status") do |_, data|
                result_output.exit_code = data.read_long
              end

              if options[:stdin]
                channel.send_data(options[:stdin])
                channel.eof!
              end
            end
          end
          session_channel.wait

          if result_output.exit_code == 0
            @logger.debug { "Command returned successfully" }
          else
            @logger.info { "Command failed with exit code #{result_output.exit_code}" }
          end
          result_output
        end

        def write_remote_file(source, destination)
          @session.scp.upload!(source, destination)
        rescue StandardError => e
          raise Bolt::Node::FileError.new(e.message, 'WRITE_ERROR')
        end

        def make_tempdir
          if target.options['tmpdir']
            tmppath = "#{target.options['tmpdir']}/#{SecureRandom.uuid}"
            command = ['mkdir', '-m', 700, tmppath]
          else
            command = ['mktemp', '-d']
          end
          result = execute(command)
          if result.exit_code != 0
            raise Bolt::Node::FileError.new("Could not make tempdir: #{result.stderr.string}", 'TEMPDIR_ERROR')
          end
          path = tmppath || result.stdout.string.chomp
          RemoteTempdir.new(self, path)
        end

        # A helper to create and delete a tempdir on the remote system. Yields the
        # directory name.
        def with_remote_tempdir
          dir = make_tempdir
          yield dir
        ensure
          dir&.delete
        end

        def write_remote_executable(dir, file, filename = nil)
          filename ||= File.basename(file)
          remote_path = "#{dir}/#{filename}"
          write_remote_file(file, remote_path)
          make_executable(remote_path)
          remote_path
        end

        def make_executable(path)
          result = execute(['chmod', 'u+x', path])
          if result.exit_code != 0
            message = "Could not make file '#{path}' executable: #{result.stderr.string}"
            raise Bolt::Node::FileError.new(message, 'CHMOD_ERROR')
          end
        end
      end
    end
  end
end
