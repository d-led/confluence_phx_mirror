defmodule Mix.Tasks.Lint.SobelowTest do
  @moduledoc """
  The lint step drops exactly the lockfile warning and nothing else: a step that
  hides output is only acceptable if it can be shown what it hides.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Lint.Sobelow

  @locked MapSet.new(["bandit", "credo"])

  test "the lockfile warning about a locked package is dropped" do
    {kept, dropped} = Sobelow.split(quoted_key("bandit", 2), @locked)

    refute kept =~ "quoted keyword"
    assert dropped == 1
  end

  test "one is dropped per package, and the rest of the scan is untouched" do
    output =
      quoted_key("bandit", 2) <>
        "\n\n" <>
        quoted_key("credo", 3) <>
        "\n\n" <>
        "... SCAN COMPLETE ...\n"

    {kept, _dropped} = Sobelow.split(output, @locked)

    assert kept =~ "... SCAN COMPLETE ..."
    refute kept =~ "quoted keyword"
  end

  test "a quoted key this project does not lock is kept" do
    {kept, dropped} = Sobelow.split(quoted_key("some-other-package", 2), @locked)

    assert kept =~ "some-other-package"
    assert dropped == 0
  end

  test "a warning from our own source is kept" do
    own = ~s(warning: variable "x" is unused\n└─ lib/example.ex:4:5\n)

    {kept, dropped} = Sobelow.split(own, @locked)

    assert kept == own
    assert dropped == 0
  end

  test "findings and the scan's summary pass through unchanged" do
    findings = "XSS.Raw: XSS - Low Confidence\n\n... SCAN COMPLETE ...\n"

    assert Sobelow.split(findings, @locked) == {findings, 0}
  end

  defp quoted_key(package, line) do
    ~s(warning: found quoted keyword "#{package}" but the quotes are not required. Note that keywords are always atoms\n└─ nofile:#{line}:3\n)
  end
end
