defmodule ConfluencePhxMirror.Resources.DeviceTest do
  @moduledoc """
  The room left on the device behind a path, as far as this machine can be
  asked for it.

  The Windows half is answered here rather than on Windows: what `:disksup` says
  about a volume is a tuple, and a volume it could not measure — zeros, not an
  error — is the case worth naming.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Resources.Device

  describe "a volume Windows reports" do
    test "its size in bytes, its free room, and the share of it in use" do
      assert %{
               mount: "c:/",
               total_bytes: 512_000_000_000,
               used_bytes: 409_600_000_000,
               free_bytes: 102_400_000_000,
               percent: 80
             } = Device.from_volume([{~c"c:/", 500_000_000, 100_000_000, 80}])
    end

    test "a volume the system would not measure is nothing to report" do
      assert Device.from_volume([{~c"c:/", 0, 0, 0}]) == nil
    end

    test "no answer at all is nothing to report" do
      assert Device.from_volume(nil) == nil
    end
  end
end
