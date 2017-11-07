require 'winrm'
require 'winrm-fs'
require 'bolt/result'

module Bolt
  class WinRM < Node
    def initialize(host, port, user, password, shell: :powershell, **kwargs)
      super(host, port, user, password, **kwargs)

      @shell = shell
      @endpoint = "http://#{host}:#{port}/wsman"
    end

    def connect
      @connection = ::WinRM::Connection.new(endpoint: @endpoint,
                                            user: @user,
                                            password: @password)
      @connection.logger = @transport_logger

      @session = @connection.shell(@shell)
      @session.run('$PSVersionTable.PSVersion')
      @logger.debug { "Opened session" }
    rescue ::WinRM::WinRMAuthorizationError
      raise Bolt::Node::ConnectError.new(
        "Authentication failed for #{@endpoint}",
        'AUTH_ERROR'
      )
    rescue StandardError => e
      raise Bolt::Node::ConnectError.new(
        "Failed to connect to #{@endpoint}: #{e.message}",
        'CONNECT_ERROR'
      )
    end

    def disconnect
      @session.close if @session
      @logger.debug { "Closed session" }
    end

    def shell_init
      return Bolt::Node::Success.new if @shell_initialized
      result = execute(<<-PS)

$ENV:PATH += ";${ENV:ProgramFiles}\\Puppet Labs\\Puppet\\bin\\;" +
  "${ENV:ProgramFiles}\\Puppet Labs\\Puppet\\sys\\ruby\\bin\\"
$ENV:RUBYLIB = "${ENV:ProgramFiles}\\Puppet Labs\\Puppet\\puppet\\lib;" +
  "${ENV:ProgramFiles}\\Puppet Labs\\Puppet\\facter\\lib;" +
  "${ENV:ProgramFiles}\\Puppet Labs\\Puppet\\hiera\\lib;" +
  $ENV:RUBYLIB

function Invoke-Interpreter
{
  [CmdletBinding()]
  Param (
    [Parameter()]
    [String]
    $Path,

    [Parameter()]
    [String]
    $Arguments,

    [Parameter()]
    [Int32]
    $Timeout,

    [Parameter()]
    [String]
    $StdinInput = $Null
  )

  try
  {
    if (-not (Get-Command $Path -ErrorAction SilentlyContinue))
    {
      throw "Could not find executable '$Path' in ${ENV:PATH} on target node"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo($Path, $Arguments)
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = Split-Path -Parent (Get-Command $Path).Path
    $startInfo.CreateNoWindow = $true
    if ($StdinInput) { $startInfo.RedirectStandardInput = $true }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $stdoutHandler = { if (-not ([String]::IsNullOrEmpty($EventArgs.Data))) { $Host.UI.WriteLine($EventArgs.Data) } }
    $stderrHandler = { if (-not ([String]::IsNullOrEmpty($EventArgs.Data))) { $Host.UI.WriteErrorLine($EventArgs.Data) } }
    $invocationId = [Guid]::NewGuid().ToString()

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true

    # https://msdn.microsoft.com/en-us/library/system.diagnostics.process.standarderror(v=vs.110).aspx#Anchor_2
    $stdoutEvent = Register-ObjectEvent -InputObject $process -EventName 'OutputDataReceived' -Action $stdoutHandler
    $stderrEvent = Register-ObjectEvent -InputObject $process -EventName 'ErrorDataReceived' -Action $stderrHandler
    $exitedEvent = Register-ObjectEvent -InputObject $process -EventName 'Exited' -SourceIdentifier $invocationId

    $process.Start() | Out-Null

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    if ($StdinInput)
    {
      $process.StandardInput.WriteLine($StdinInput)
      $process.StandardInput.Close()
    }

    # park current thread until the PS event is signaled upon process exit
    # OR the timeout has elapsed
    $waitResult = Wait-Event -SourceIdentifier $invocationId -Timeout $Timeout
    if (! $process.HasExited)
    {
      $Host.UI.WriteErrorLine("Process $Path did not complete in $Timeout seconds")
      return 1
    }

    return $process.ExitCode
  }
  catch
  {
    $Host.UI.WriteErrorLine($_)
    return 1
  }
  finally
  {
    @($stdoutEvent, $stderrEvent, $exitedEvent) |
      ? { $_ -ne $Null } |
      % { Unregister-Event -SourceIdentifier $_.Name }

    if ($process -ne $Null)
    {
      if (($process.Handle -ne $Null) -and (! $process.HasExited))
      {
        try { $process.Kill() } catch { $Host.UI.WriteErrorLine("Failed To Kill Process $Path") }
      }
      $process.Dispose()
    }
  }
}
PS
      @shell_initialized = true

      result
    end

    def execute(command, _ = {})
      result_output = Bolt::Node::ResultOutput.new

      @logger.debug { "Executing command: #{command}" }

      output = @session.run(command) do |stdout, stderr|
        result_output.stdout << stdout
        @logger.debug { "stdout: #{stdout}" }
        result_output.stderr << stderr
        @logger.debug { "stderr: #{stderr}" }
      end
      if output.exitcode.zero?
        @logger.debug { "Command returned successfully" }
        Bolt::Node::Success.new(result_output.stdout.string, result_output)
      else
        @logger.info { "Command failed with exit code #{output.exitcode}" }
        Bolt::Node::Failure.new(output.exitcode, result_output)
      end
    end

    # 10 minutes in seconds
    DEFAULT_EXECUTION_TIMEOUT = 10 * 60

    def execute_process(path = '', arguments = [], stdin = nil,
                        timeout = DEFAULT_EXECUTION_TIMEOUT)
      quoted_args = arguments.map do |arg|
        "'" + arg.gsub("'", "''") + "'"
      end.join(',')

      execute(<<-PS)
$quoted_array = @(
  #{quoted_args}
)

$invokeArgs = @{
  Path = "#{path}"
  Arguments = $quoted_array -Join ' '
  Timeout = #{timeout}
  #{stdin.nil? ? '' : "StdinInput = @'\n" + stdin + "\n'@"}
}

# winrm gem checks $? prior to using $LASTEXITCODE
# making it necessary to exit with the desired code to propagate status properly
exit $(Invoke-Interpreter @invokeArgs)
PS
    end

    VALID_EXTENSIONS = ['.ps1', '.rb', '.pp'].freeze

    PS_ARGS = %w[
      -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass
    ].freeze

    def process_from_extension(path)
      case Pathname(path).extname.downcase
      when '.rb'
        [
          'ruby.exe',
          ['-S', "\"#{path}\""]
        ]
      when '.ps1'
        [
          'powershell.exe',
          [*PS_ARGS, '-File', "\"#{path}\""]
        ]
      when '.pp'
        [
          'puppet.bat',
          ['apply', "\"#{path}\""]
        ]
      end
    end

    def _upload(source, destination)
      @logger.debug { "Uploading #{source} to #{destination}" }
      fs = ::WinRM::FS::FileManager.new(@connection)
      fs.upload(source, destination)
      Bolt::Node::Success.new
    rescue StandardError => ex
      Bolt::Node::ExceptionFailure.new(ex)
    end

    def make_tempdir
      result = execute(<<-PS)
$parent = [System.IO.Path]::GetTempPath()
$name = [System.IO.Path]::GetRandomFileName()
$path = Join-Path $parent $name
New-Item -ItemType Directory -Path $path | Out-Null
$path
PS
      result.then { |stdout| Bolt::Node::Success.new(stdout.chomp) }
    end

    def with_remote_file(file)
      dest = ''
      dir = ''
      result = nil

      make_tempdir.then do |value|
        dir = value
        ext = File.extname(file)
        ext = VALID_EXTENSIONS.include?(ext) ? ext : '.ps1'
        dest = "#{dir}\\#{File.basename(file, '.*')}#{ext}"
        Bolt::Node::Success.new
      end.then do
        _upload(file, dest)
      end.then do
        shell_init
      end.then do
        result = yield dest
      end.then do
        execute(<<-PS)
Remove-Item -Force "#{dest}"
Remove-Item -Force "#{dir}"
PS
        result
      end
    end

    def _run_command(command)
      execute(command)
    end

    def _run_script(script, arguments)
      @logger.info { "Running script '#{script}'" }
      with_remote_file(script) do |remote_path|
        args = [*PS_ARGS, '-File', "\"#{remote_path}\""]
        args += escape_arguments(arguments)
        execute_process('powershell.exe', args)
      end
    end

    def _run_task(task, input_method, arguments)
      @logger.info { "Running task '#{task}'" }
      @logger.debug { "arguments: #{arguments}\ninput_method: #{input_method}" }

      if STDIN_METHODS.include?(input_method)
        stdin = JSON.dump(arguments)
      end

      if ENVIRONMENT_METHODS.include?(input_method)
        arguments.reduce(Bolt::Node::Success.new) do |result, (arg, val)|
          result.then do
            cmd = "[Environment]::SetEnvironmentVariable('PT_#{arg}', '#{val}')"
            execute(cmd)
          end
        end
      else
        Bolt::Node::Success.new
      end.then do
        with_remote_file(task) do |remote_path|
          path, args = *process_from_extension(remote_path)
          execute_process(path, args, stdin)
        end
      end
    end

    def escape_arguments(arguments)
      arguments.map do |arg|
        if arg =~ / /
          "\"#{arg}\""
        else
          arg
        end
      end
    end
  end
end
