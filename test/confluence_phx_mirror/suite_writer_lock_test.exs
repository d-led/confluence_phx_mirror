defmodule ConfluencePhxMirror.SuiteWriterLockTest do
  @moduledoc """
  Against SQLite the suite runs one writer at a time, and the lock it takes has to
  outlive the test that took it.

  `:global` drops a lock when the process that asked for it dies, and a test
  process dies *before* its `on_exit` callbacks have rolled the transaction back.
  A lock held by the test process itself therefore let the next test start
  writing while the previous one was still finding its way back — answered
  "Database busy", once, on a CI runner where the two windows overlapped.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.DataCase

  test "the lock outlives the process that asked for it, and is given back on release" do
    parent = self()

    # The asker is gone the moment it has answered — which is exactly where a
    # test process stands when its `on_exit` callbacks begin.
    asker = spawn(fn -> send(parent, {:asked, DataCase.hold_writer_lock()}) end)

    assert_receive {:asked, holder}
    ref = Process.monitor(asker)
    assert_receive {:DOWN, ^ref, :process, ^asker, _reason}

    assert :global.set_lock({:sqlite_suite_writer, self()}, [node()], 0) == false,
           "the lock went with the asker: a second test could write while the first was rolling back"

    DataCase.release_writer_lock(holder)

    assert :global.set_lock({:sqlite_suite_writer, self()}, [node()], 0),
           "the lock was not given back: the next test would wait for ever"

    :global.del_lock({:sqlite_suite_writer, self()})
  end
end
