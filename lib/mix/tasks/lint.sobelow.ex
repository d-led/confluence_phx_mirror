defmodule Mix.Tasks.Lint.Sobelow do
  @shortdoc "Runs sobelow, attributing the mix.lock parser warning it cannot avoid"

  @moduledoc """
  The sobelow step of `mix lint`.

      mix lint.sobelow --config

  Sobelow 0.16.0 reads `mix.lock` with `Code.string_to_quoted/1`
  (`Sobelow.Vuln.locked_version/2`) to report vulnerable dependency versions, and
  Elixir 1.20 warns about every quoted key in that file: sixty-nine lines, one
  per dependency, on every run. Nobody can act on them — the lockfile is Hex's to
  write, and the call that warns belongs to the dependency — and they drown the
  warnings that *are* ours, which `compile --warnings-as-errors` turns into a
  failed build.

  So the run happens in a child, and exactly one shape of block is taken out:

      warning: found quoted keyword "<a package this project locks>" …
      └─ nofile:<line>:<column>

  Both halves are required, so a warning from our own source — which carries a
  real filename — still prints and still fails the build, and so does a
  quoted-key warning about anything this project does not lock. What was removed
  is counted and said out loud, rather than silently dropped.
  """

  use Mix.Task

  # The whole two-line block, and nothing else. A block arrives trimmed, because
  # interleaved output leaves blank lines on either side of it.
  @quoted_key ~r/\Awarning: found quoted keyword "([^"]+)" but the quotes are not required[^\n]*\n└─ nofile:\d+:\d+\z/

  @impl true
  def run(args) do
    locked = locked_packages()

    {output, status} =
      System.cmd("mix", ["sobelow" | args],
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(Mix.env())}]
      )

    {kept, dropped} = split(output, locked)

    IO.write(kept)

    if dropped > 0 do
      Mix.shell().info(
        "\n#{dropped} quoted-key warning(s) from mix.lock dropped: " <>
          "sobelow parses it, Elixir 1.20 warns about its keys, neither is ours"
      )
    end

    if status != 0, do: exit({:shutdown, status})
  end

  @doc false
  # Splits the child's output into blocks and keeps every block that is not the
  # lockfile warning about a package this project locks.
  def split(output, locked) do
    blocks = String.split(output, "\n\n")

    {kept, dropped} = Enum.split_with(blocks, &(not lockfile_warning?(&1, locked)))

    {Enum.join(kept, "\n\n"), length(dropped)}
  end

  defp lockfile_warning?(block, locked) do
    case Regex.run(@quoted_key, String.trim(block)) do
      [_, package] -> MapSet.member?(locked, package)
      nil -> false
    end
  end

  # The keys of mix.lock, read as text: evaluating the file is what warns.
  defp locked_packages do
    "mix.lock"
    |> File.read!()
    |> then(&Regex.scan(~r/^\s*"([^"]+)":/m, &1, capture: :all_but_first))
    |> List.flatten()
    |> MapSet.new()
  end
end
