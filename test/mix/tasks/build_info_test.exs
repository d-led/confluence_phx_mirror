defmodule Mix.Tasks.Build.InfoTest do
  @moduledoc """
  The stamp a build writes: a wall clock a person recognises, and the offset it
  was read in.

  `2026-11-05 06:23+01:00` rather than `2026-11-05T05:23:00Z`: a build happens in
  somebody's day, and UTC makes every reader convert it back before it means
  anything.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Build.Info

  test "an offset east of Greenwich moves the clock forward and says so" do
    assert Info.stamp(~U[2026-11-05 05:23:41Z], 3_600) == "2026-11-05 06:23+01:00"
  end

  test "an offset west of Greenwich moves the clock back and says so" do
    assert Info.stamp(~U[2026-11-05 05:23:41Z], -5 * 3_600) == "2026-11-05 00:23-05:00"
  end

  test "no offset is written as +00:00, not as nothing" do
    assert Info.stamp(~U[2026-11-05 05:23:41Z], 0) == "2026-11-05 05:23+00:00"
  end

  test "an offset that is not a whole hour still reads as a time" do
    # India, +05:30 — the case a format that assumed whole hours gets wrong.
    assert Info.stamp(~U[2026-11-05 05:23:41Z], 5 * 3_600 + 1_800) == "2026-11-05 10:53+05:30"
  end

  test "the clock a build reads is the one it was running on" do
    # Whatever this machine's offset is, `build_info/0` stamps the same format —
    # and it is this machine's, not a constant.
    built_at = Info.build_info().built_at

    assert built_at =~ ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}[+-]\d{2}:\d{2}\z/
  end
end
