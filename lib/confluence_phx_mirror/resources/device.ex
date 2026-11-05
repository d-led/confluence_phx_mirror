defmodule ConfluencePhxMirror.Resources.Device do
  @moduledoc """
  The filesystem a path sits on: how big it is, how much of it is used, how much
  is left.

  Two operating systems, two ways of asking, one answer. A Unix machine has
  `df`, whose `-P` is the portable spelling — POSIX output, one line, path in,
  mount point out. A Windows machine has neither `df` nor a mount table: a path
  belongs to a volume, and `os_mon`'s port program asks the system for that
  volume's size, on the port `memsup` keeps open anyway.

  Neither answer is promised. A store on a network share, a machine where `df`
  is not installed, a volume the system calls removable — each of those is
  `nil`: a reason for a screen to say nothing about the room left, not a reason
  for the process that asked to fall over.
  """

  @typedoc """
  `mount` is the filesystem as the operating system names it — "/data" on
  Linux, "c:/" on Windows.
  """
  @type t :: %{
          mount: String.t(),
          total_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          percent: non_neg_integer()
        }

  @doc """
  The device behind `path`, or `nil` when the operating system would not say.
  """
  @spec read(Path.t()) :: t | nil
  def read(path) do
    case :os.type() do
      {:win32, _windows} -> from_volume(volume_report(path))
      _unix -> from_df(path)
    end
  end

  # `df -P`: kilobytes, one line per filesystem, and the mount point last — so a
  # directory with a space in its name stays one field. The program is named the
  # way the system names it, not resolved through `find_executable` first: a
  # resolved path is a variable standing where a command belongs, which is what
  # a command-injection check has to treat as untrusted. A machine without `df`
  # is a machine to say nothing about, so the raise it produces is caught below
  # rather than avoided by looking the program up.
  defp from_df(path) do
    with target when is_binary(target) <- existing(path),
         {:ok, output} <- df_report(target),
         [_header, line | _rest] <- String.split(output, "\n", trim: true),
         [_filesystem, total, used, free, capacity | mount] <- String.split(line),
         {:ok, total} <- integer(total),
         {:ok, used} <- integer(used),
         {:ok, free} <- integer(free),
         {:ok, percent} <- integer(String.trim_trailing(capacity, "%")) do
      %{
        mount: Enum.join(mount, " "),
        total_bytes: kibibytes(total),
        used_bytes: kibibytes(used),
        free_bytes: kibibytes(free),
        percent: percent
      }
    else
      _not_reported -> nil
    end
  end

  defp df_report(target) do
    case System.cmd("df", ["-kP", target], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> :error
    end
  rescue
    # `System.cmd/3` raises `:enoent` when the program is not on this machine.
    ErlangError -> :error
  end

  defp volume_report(path) do
    if volume_asking_up?(), do: :disksup.get_disk_info(volume_root(path))
  end

  # Both halves of the OS_MON port must be running before it can be asked:
  # `disksup` takes the request, `os_mon_sysinfo` owns the port program that
  # answers it. Either one missing is a machine to say nothing about rather than
  # a `noproc` exit inside the process that keeps the store's figures.
  defp volume_asking_up? do
    is_pid(Process.whereis(:disksup)) and is_pid(Process.whereis(:os_mon_sysinfo))
  end

  # The system answers for a volume's root ("c:/"), not for a directory inside
  # it: deeper than that is `DRIVE_NO_ROOT_DIR`, which comes back as zeros.
  # Spelled out rather than left to `Path.split/1`, whose answer depends on the
  # machine doing the splitting — and the machine doing this is a Windows one.
  # A path with no drive letter (a share, \\server\share) is handed over whole:
  # the system will call it remote and decline, which is the answer it deserves.
  defp volume_root(path) do
    case Regex.run(~r/^[A-Za-z]:[\\\/]/, path) do
      [root] -> String.to_charlist(root)
      nil -> String.to_charlist(path)
    end
  end

  @doc """
  The device a volume reports, from `:disksup`'s answer for it.

  Public because it is what `read/1` runs on Windows, where this suite does not:
  a volume the system could not measure comes back as zeros rather than as an
  error, and that is the answer worth naming in a test.
  """
  @spec from_volume([{charlist(), non_neg_integer(), non_neg_integer(), non_neg_integer()}] | nil) ::
          t | nil
  def from_volume([{drive, total_kib, free_kib, percent} | _more]) when total_kib > 0 do
    %{
      mount: List.to_string(drive),
      total_bytes: kibibytes(total_kib),
      used_bytes: kibibytes(total_kib - free_kib),
      free_bytes: kibibytes(free_kib),
      percent: percent
    }
  end

  def from_volume(_not_measured), do: nil

  defp kibibytes(count), do: count * 1024

  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> {:ok, number}
      _not_a_number -> :error
    end
  end

  # `df` wants a path that exists; before the first attachment the store's own
  # directory may not — the disk is still there, one level up.
  defp existing(path) do
    cond do
      File.exists?(path) -> path
      Path.dirname(path) == path -> path
      true -> existing(Path.dirname(path))
    end
  end
end
