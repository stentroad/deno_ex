defmodule DenoEx do
  @moduledoc """
  DenoEx is used to run javascript and typescript
  files in a safe environment.
  """

  @type script() :: String.t()
  @type script_arguments() :: [String.t()]
  @type options() :: keyword()

  @default_executable_path Application.compile_env(
                             :deno_ex,
                             :default_exectutable_path,
                             :deno_ex |> :code.priv_dir() |> Path.join("bin")
                           )

  @run_options_schema [
                        deno_path: [
                          type: :string,
                          doc: "the path where the deno executable is installed."
                        ],
                        timeout: [
                          type: :pos_integer,
                          default: 100,
                          doc: "Timeout in milliseconds to wait for the script to run before aborting."
                        ],
                        allow_env: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          This option allows read and write access to environment variables.

                          true: allows full access to the environment variables
                          [String.t()]: allows access to only the subset of variables in the list.
                          """
                        ],
                        allow_sys: [
                          type: {:or, [:boolean, list: :string]},
                          doc: """
                          This option allows axxess to APIs that provide system information.
                          ie. hostname, memory usage

                          true: allows full access
                          [String.t()]: allows access to only the subset calls.
                          hostname, osRelease, osUptime, loadavg, networkInterfaces,
                          systemMemoryInfo, uid, and gid
                          """
                        ],
                        allow_hrtime: [
                          type: :boolean,
                          doc: """
                          Allow high-resolution time measurement. High-resolution time can be used in timing attacks and fingerprinting.
                          """
                        ]
                      ]
                      |> NimbleOptions.new!()
  @doc """
  Uses `deno run` to run a Deno script.

  ## Options

    #{NimbleOptions.docs(@run_options_schema)}

    Please refere to [Deno Permissions](https://deno.com/manual@v1.33.1/basics/permissions) for more details.
  """
  @spec run(script, script_arguments, options) :: {:ok, String.t()} | {:error, term()}
  def run(script, script_args \\ [], options \\ []) do
    with {:ok, options} <- NimbleOptions.validate(options, @run_options_schema),
         {exec_path, deno_options} = Keyword.pop(options, :deno_path, executable_path()),
         {timeout, deno_options} = Keyword.pop(deno_options, :timeout) do
      deno_options = Enum.map(deno_options, &to_command_line_option/1)

      deno_path =
        [
          "#{exec_path}/deno run",
          deno_options,
          script,
          script_args
        ]
        |> List.flatten()
        |> Enum.join(" ")

      {:ok, pid, os_pid} =
        deno_path
        |> :exec.run([:stdout, :stderr, :monitor])

      # Initial state for reduce
      initial_reduce_results = %{
        stdout: "",
        stderr: []
      }

      result =
        [nil]
        |> Stream.cycle()
        |> Enum.reduce_while(initial_reduce_results, fn _, acc ->
          receive do
            {:DOWN, ^os_pid, _, ^pid, {:exit_status, exit_status}} when exit_status != 0 ->
              error = "Deno script exited with status code #{inspect(exit_status)}\n"
              existing_errors = Map.get(acc, :stderr, [])
              {:halt, Map.put(acc, :stderr, [error | existing_errors])}

            {:DOWN, ^os_pid, _, ^pid, :normal} ->
              {:halt, acc}

            {:stderr, ^os_pid, error} ->
              error = String.trim(error)
              existing_errors = Map.get(acc, :stderr, [])
              {:cont, Map.put(acc, :stderr, [error | existing_errors])}

            {:stdout, ^os_pid, compiled_template_fragment} ->
              aggregated_template = Map.get(acc, :stdout, "")
              {:cont, Map.put(acc, :stdout, aggregated_template <> compiled_template_fragment)}
          after
            timeout ->
              :exec.kill(os_pid, :sigterm)
              error = "Deno script timed out after #{timeout} millisecond(s)"
              existing_errors = Map.get(acc, :stderr, [])
              {:halt, Map.put(acc, :stderr, [error | existing_errors])}
          end
        end)

      case result do
        %{stderr: [], stdout: compiled_template} ->
          {:ok, compiled_template}

        %{stderr: errors} ->
          {:error, Enum.join(errors, "\n")}
      end
    end
  end

  def executable_path do
    System.get_env("DENO_PATH", @default_executable_path)
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
end
