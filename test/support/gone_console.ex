defmodule ConfluencePhxMirror.Test.GoneConsole do
  @moduledoc """
  A console handler that cannot write.

  What the desktop's console becomes once the window stops reading the sidecar's
  output: the next write raises `:badarg` from `:erlang.display_string` (cause
  `:epipe`) in whichever process logged.
  """

  def log(_event, _config), do: raise("the console has gone away")
end
