defmodule Stokowski.ProcessLifecycleTest do
  use ExUnit.Case, async: false

  @cleanup_timeout 5_000

  @tag :tmp_dir
  test "TERM grace followed by group KILL cleans a stubborn three-level tree", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    script = Path.expand("../support/stubborn_process_tree.py", __DIR__)
    pid_file = Path.join(tmp_dir, "pids")
    leader_file = "#{pid_file}.leader"

    assert {:ok, fixture} =
             YamlElixir.read_from_file(
               Path.expand("../fixtures/runners/process-lifecycle.yaml", __DIR__)
             )

    assert fixture["platforms"] != []
    [term_signal, _grace, kill_signal] = fixture["termination"]

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        args: [script, "parent", pid_file]
      ])

    port_pid = Port.info(port)[:os_pid]

    on_exit(fn ->
      cleanup_pids = read_pids(pid_file)
      cleanup_leader = List.first(cleanup_pids) || read_pid(leader_file) || port_pid
      if is_integer(cleanup_leader), do: group_signal(kill_signal, cleanup_leader)

      if is_list(Port.info(port)), do: Port.close(port)
    end)

    pids = await_pids(pid_file)
    [session_leader | _] = pids

    assert {_, 0} = group_signal(term_signal, session_leader)
    Process.sleep(50)
    assert Enum.all?(pids, &alive?/1)

    assert {_, 0} = group_signal(kill_signal, session_leader)
    assert eventually(fn -> Enum.all?(pids, &(not alive?(&1))) end, @cleanup_timeout)
    assert_receive {^port, {:exit_status, _status}}, @cleanup_timeout
  end

  defp await_pids(path, attempts \\ 200)
  defp await_pids(_path, 0), do: flunk("process tree did not become ready")

  defp await_pids(path, attempts) do
    pids = read_pids(path)

    if length(pids) == 3 do
      pids
    else
      Process.sleep(10)
      await_pids(path, attempts - 1)
    end
  end

  defp read_pids(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split()
        |> Enum.flat_map(fn value ->
          case Integer.parse(value) do
            {pid, ""} -> [pid]
            _invalid -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp read_pid(path) do
    case read_pids(path) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  defp group_signal(signal, pid),
    do: System.cmd("/bin/kill", ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true)

  defp alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(check, timeout), do: eventually(check, timeout, 10)
  defp eventually(_check, timeout, _interval) when timeout <= 0, do: false

  defp eventually(check, timeout, interval) do
    if check.() do
      true
    else
      Process.sleep(interval)
      eventually(check, timeout - interval, interval)
    end
  end
end
