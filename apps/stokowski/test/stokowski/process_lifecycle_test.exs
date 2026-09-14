defmodule Stokowski.ProcessLifecycleTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "TERM grace followed by group KILL cleans a stubborn three-level tree", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    script = Path.expand("../support/stubborn_process_tree.py", __DIR__)
    pid_file = Path.join(tmp_dir, "pids")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        args: [script, "parent", pid_file]
      ])

    pids = await_pids(pid_file)
    [group_leader | _] = pids

    on_exit(fn ->
      if Enum.any?(pids, &alive?/1), do: group_signal("KILL", group_leader)
    end)

    assert {_, 0} = group_signal("TERM", group_leader)
    Process.sleep(50)
    assert Enum.all?(pids, &alive?/1)

    assert {_, 0} = group_signal("KILL", group_leader)
    assert_receive {^port, {:exit_status, _status}}, 2_000
    assert eventually(fn -> Enum.all?(pids, &(not alive?(&1))) end)
  end

  defp await_pids(path, attempts \\ 200)
  defp await_pids(_path, 0), do: flunk("process tree did not become ready")

  defp await_pids(path, attempts) do
    pids =
      case File.read(path) do
        {:ok, contents} -> contents |> String.split() |> Enum.map(&String.to_integer/1)
        {:error, _reason} -> []
      end

    if length(pids) == 3 do
      pids
    else
      Process.sleep(10)
      await_pids(path, attempts - 1)
    end
  end

  defp group_signal(signal, pid),
    do: System.cmd("/bin/kill", ["-#{signal}", "-#{pid}"], stderr_to_stdout: true)

  defp alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
