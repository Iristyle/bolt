# frozen_string_literal: true

require 'shellwords'
require 'bolt/transport/base'

module Bolt
  module Transport
    class Docker < Base
      def self.options
        %w[service-url service-options tmpdir interpreters]
      end

      def provided_features
        ['shell']
      end

      def self.validate(options)
        if (url = options['service-url'])
          unless url.instance_of?(String)
            raise Bolt::ValidationError, 'service-url must be a string'
          end
        end

        if (opts = options['service-options'])
          unless opts.instance_of?(Hash)
            raise Bolt::ValidationError, 'service-options must be a hash'
          end
        end
      end

      def with_connection(target)
        conn = Connection.new(target)
        conn.connect
        yield conn
      end

      def upload(target, source, destination, _options = {})
        with_connection(target) do |conn|
          conn.with_remote_tempdir do |dir|
            basename = File.basename(destination)
            tmpfile = "#{dir}/#{basename}"
            if File.directory?(source)
              conn.write_remote_directory(source, tmpfile)
            else
              conn.write_remote_file(source, tmpfile)
            end

            _, stderr, exitcode = conn.execute('mv', tmpfile, destination, {})
            if exitcode != 0
              message = "Could not move temporary file '#{tmpfile}' to #{destination}: #{stderr}"
              raise Bolt::Node::FileError.new(message, 'MV_ERROR')
            end
          end
          Bolt::Result.for_upload(target, source, destination)
        end
      end

      def run_command(target, command, _options = {})
        with_connection(target) do |conn|
          stdout, stderr, exitcode = conn.execute(*Shellwords.split(command), {})
          Bolt::Result.for_command(target, stdout, stderr, exitcode)
        end
      end

      def run_script(target, script, arguments, _options = {})
        # unpack any Sensitive data
        arguments = unwrap_sensitive_args(arguments)

        with_connection(target) do |conn|
          conn.with_remote_tempdir do |dir|
            remote_path = conn.write_remote_executable(dir, script)
            stdout, stderr, exitcode = conn.execute(remote_path, *arguments, {})
            Bolt::Result.for_command(target, stdout, stderr, exitcode)
          end
        end
      end

      def run_task(target, task, arguments, _options = {})
        implementation = task.select_implementation(target, provided_features)
        executable = implementation['path']
        input_method = implementation['input_method']
        extra_files = implementation['files']
        input_method ||= 'both'

        # unpack any Sensitive data
        arguments = unwrap_sensitive_args(arguments)
        with_connection(target) do |conn|
          execute_options = {}
          execute_options[:interpreter] = select_interpreter(executable, target.options['interpreters'])
          conn.with_remote_tempdir do |dir|
            if extra_files.empty?
              task_dir = dir
            else
              # TODO: optimize upload of directories
              arguments['_installdir'] = dir
              task_dir = File.join(dir, task.tasks_dir)
              conn.mkdirs([task_dir] + extra_files.map { |file| File.join(dir, File.dirname(file['name'])) })
              extra_files.each do |file|
                conn.write_remote_file(file['path'], File.join(dir, file['name']))
              end
            end

            remote_task_path = conn.write_remote_executable(task_dir, executable)

            if STDIN_METHODS.include?(input_method)
              require 'json'
              execute_options[:stdin] = StringIO.new(JSON.dump(arguments))
            end

            if ENVIRONMENT_METHODS.include?(input_method)
              execute_options[:environment] = envify_params(arguments)
            end

            stdout, stderr, exitcode = conn.execute(remote_task_path, execute_options)
            Bolt::Result.for_task(target, stdout, stderr, exitcode)
          end
        end
      end

      def connected?(target)
        with_connection(target) { true }
      rescue Bolt::Node::ConnectError
        false
      end
    end
  end
end

require 'bolt/transport/docker/connection'
