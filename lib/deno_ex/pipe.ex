defmodule DenoEx.Pipe do
  @derive {Inspect, only: [:status]}
  @moduledoc """
  The DenoEx pipe.

  This module defines a struct and the main functions for working with deno pipes
  and their responses.
  """
  @run_options_schema [
                        deno_location: [
                          type: :string,
                          doc: """
                          Sets the path where the deno executable is located.

                          Note: It does not include the deno executable. If the executable is located at
                          `/usr/bin/deno` then the `deno_location` should be `/usr/bin`.
                          """
                        ],
                        allow_env: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allows read and write access to environment variables.

                          `true`: allows full access to the environment variables

                          `[String.t()]`: allows access to only the subset of variables in the list.
                          """
                        ],
                        allow_sys: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allows access to APIs that provide system information.
                          i.e. hostname, memory usage

                          `true`: allows full access

                          `[String.t()]`: allows access to only the subset calls.
                          hostname, osRelease, osUptime, loadavg, networkInterfaces,
                          systemMemoryInfo, uid, and gid
                          """
                        ],
                        allow_net: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allows network access.

                          `true`: allows full access to the network

                          `[String.t()]`: allows access to only the network connections specified
                          ie. 127.0.0.1:4000, 127.0.0.1, :4001
                          """
                        ],
                        allow_hrtime: [
                          type: :boolean,
                          doc: """
                          Allows high-resolution time measurement. High-resolution time can be used in timing attacks and fingerprinting.
                          """
                        ],
                        allow_ffi: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allow loading of dynamic libraries.

                          ## WARNING:

                          Be aware that dynamic libraries are not run in a sandbox and therefore
                          do not have the same security restrictions as the Deno process.
                          Therefore, use it with caution.

                          `true`: allows all dlls to be accessed

                          `[Path.t()]`: A list of paths to dlls that will be accessible
                          """
                        ],
                        allow_run: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allow running subprocesses.

                          ## WARNING

                          Be aware that subprocesses are not run in a sandbox and therefore do not have
                          the same security restrictions as the Deno process. Therefore, use it with caution.

                          `true`: allows all subprocesses to be run

                          `[Path.t()]`: A list of subprocesses to run
                          """
                        ],
                        allow_write: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allow the ability to write files.

                          `true`: allows all files to be written

                          `[Path.t()]`: A list of files that can be written
                          """
                        ],
                        allow_read: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          Allow the ability to read files.

                          `true`: allows all files to be read

                          `[Path.t()]`: A list of files that can be read
                          """
                        ],
                        allow_all: [
                          type: :boolean,
                          doc: "Turns on all options and bypasses all security measures"
                        ]
                      ]
                      |> NimbleOptions.new!()

  @typedoc "status of the pipe"
  @type status :: :initialized | :running | {:exited, :normal | pos_integer()} | :timeout

  @typedoc "types of datastreams"
  @type datastream :: :stderr | :stdout

  @typedoc "#{__MODULE__}"
  @opaque t() :: %__MODULE__{
            command: {:file, [String.t()]} | {:stdin, [String.t()], [String.t()]},
            pid: pid(),
            os_pid: integer(),
            stderr: list(String.t()),
            stdout: list(String.t()),
            status: status()
          }
  @opaque t(status) :: %__MODULE__{status: status}

  @typedoc "arguments for deno"
  @type options() :: keyword(unquote(NimbleOptions.option_typespec(@run_options_schema)))

  defstruct command: [""],
            pid: nil,
            os_pid: nil,
            stderr: [],
            stdout: [],
            status: :initialized

  @doc """
  Initializes a deno pipe with everything needed to run a deno script.

    ## Options

    #{NimbleOptions.docs(@run_options_schema)}

    Please refer to [Deno Permissions](https://deno.com/manual@v1.33.1/basics/permissions) for more details.

  ## Examples

       iex> DenoEx.Pipe.new({:file, Path.join(~w[test support hello.ts])})
       #DenoEx.Pipe<status: :initialized, ...>

       iex> DenoEx.Pipe.new({:file, Path.join(~w[test support args_echo.ts])}, ~w[foo bar])
       #DenoEx.Pipe<status: :initialized, ...>
  """
  @spec new(DenoEx.script(), DenoEx.script_arguments(), options()) :: t(:initialized) | {:error, String.t()}
  def new(script, script_args \\ [], options \\ [])

  def new({:stdin, script}, script_args, options) do
    with {:ok, options} <- NimbleOptions.validate(options, @run_options_schema),
         {deno_location, deno_options} <-
           Keyword.pop(options, :deno_location, DenoEx.executable_location()) do
      deno_options = Enum.map(deno_options, &to_command_line_option/1)

      %__MODULE__{
        command: {
          :stdin,
          [
            Path.join(deno_location, "deno"),
            "run",
            deno_options,
            script_args,
            "-"
          ],
          script
        }
      }
    end
  end

  def new({:file, script}, script_args, options) do
    with {:ok, options} <- NimbleOptions.validate(options, @run_options_schema),
         {deno_location, deno_options} <-
           Keyword.pop(options, :deno_location, DenoEx.executable_location()) do
      deno_options = Enum.map(deno_options, &to_command_line_option/1)

      %__MODULE__{
        command:
          {:file,
           [
             Path.join(deno_location, "deno"),
             "run",
             deno_options,
             script,
             script_args
           ]}
      }
    end
  end

  @doc """
  Executes the deno pipe in another process and sets up to monitor the results.

  While running a `Deno.Pipe` sends messages back to the calling process.

  ## Examples

       iex> DenoEx.Pipe.new({:file, Path.join(~w[test support hello.ts])}) |> DenoEx.Pipe.run()
       #DenoEx.Pipe<status: :running, ...>
  """
  @spec run(t(:initialized)) :: t(:running)
  def run(%__MODULE__{status: :initialized, command: {:file, command}} = pipe) do
    start_proccess(pipe, command)
  end

  def run(%__MODULE__{status: :initialized, command: {:stdin, command, input}} = pipe) do
    pipe = start_proccess(pipe, command)

    :ok = __MODULE__.send(pipe, IO.iodata_to_binary(input))
    :ok = __MODULE__.send(pipe, :eof)

    pipe
  end

  @doc """
  Sends data to a running process
  """
  @spec send(t(:running), String.t() | :eof) :: :ok
  def send(%{pid: pid, status: :running}, data) when is_binary(data) or data == :eof do
    :exec.send(pid, data)
  end

  @doc """
  Waits for a pipe to finish and collects the results.

  ## Examples

       iex> {:ok, pipe} = DenoEx.Pipe.new({:file, Path.join(~w[test support hello.ts])}) |> DenoEx.Pipe.run() |> DenoEx.Pipe.yield()
       iex> pipe
       #DenoEx.Pipe<status: {:exit, :normal}, ...>

       iex> {:timeout, pipe} = DenoEx.Pipe.new({:file, Path.join(~w[test support hello.ts])}) |> DenoEx.Pipe.run() |> DenoEx.Pipe.yield(1)
       iex> pipe
       #DenoEx.Pipe<status: :timeout, ...>
  """
  @spec yield(t(:running), timeout()) ::
          {:ok, t({:exit, :normal})} | {:error, t({:exit, pos_integer()})} | {:timeout, t(:timeout)}
  def yield(%__MODULE__{status: :running} = pipe, timeout \\ :timer.seconds(5)) do
    pid = pipe.pid
    os_pid = pipe.os_pid

    pipe
    |> Stream.iterate(fn pipe ->
      receive do
        {:DOWN, ^os_pid, _, ^pid, {:exit_status, exit_status}} when exit_status != 0 ->
          %{pipe | status: {:exit, exit_status}}

        {:DOWN, ^os_pid, _, ^pid, :normal} ->
          %{pipe | status: {:exit, :normal}}

        {:stderr, ^os_pid, error} ->
          error = String.trim(error)
          %{pipe | stderr: [error | pipe.stderr]}

        {:stdout, ^os_pid, output} ->
          %{pipe | stdout: [output | pipe.stdout]}
      after
        timeout ->
          _ = :exec.kill(os_pid, :sigterm)
          %{pipe | status: :timeout}
      end
    end)
    |> Enum.find(&finished?/1)
    |> then(fn
      %__MODULE__{status: {:exit, :normal}} = pipe ->
        {:ok, pipe}

      %__MODULE__{status: {:exit, code}} = pipe when is_integer(code) ->
        {:error, pipe}

      %__MODULE__{status: :timeout} = pipe ->
        {:timeout, pipe}
    end)
  end

  @doc "get the buffer from the desired datastream"
  @spec output(t(status()), datastream()) :: [String.t()]
  def output(pipe, datastream) when datastream in [:stderr, :stdout] do
    pipe
    |> Map.get(datastream)
    |> Enum.reverse()
  end

  @doc "returns if the pipe is finished running or not"
  @spec finished?(t(status())) :: boolean()
  def finished?(pipe) do
    pipe.status not in [:running, :initialized]
  end

  @doc """
  returns the exit code of a finished pipe
  """
  @spec status(t(status())) :: status()
  def status(%__MODULE__{status: status}) do
    status
  end

  @doc false
  def run_options_schema do
    @run_options_schema
  end

  defp to_command_line_option({option, true}) do
    string_option =
      option
      |> to_string()
      |> String.replace("_", "-")

    "--#{string_option}"
  end

  defp to_command_line_option({_option, false}) do
    ""
  end

  defp to_command_line_option({option, values}) when is_list(values) do
    string_option =
      option
      |> to_string()
      |> String.replace("_", "-")

    string_values = Enum.join(values, ",")
    "--#{string_option}=#{string_values}"
  end

  defp start_proccess(pipe, command) do
    {:ok, pid, os_pid} =
      command
      |> List.flatten()
      |> Enum.join(" ")
      |> :exec.run([:stdout, :stderr, :monitor, :stdin])

    %{pipe | status: :running, pid: pid, os_pid: os_pid}
  end
end
