defmodule ConfluencePhxMirrorWeb.AdminAuditExportTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Audit.{Entry, Export}

  setup do
    :ok
  end

  describe "who may download it" do
    test "a member is refused", %{conn: conn} do
      member = user_fixture(%{email: "member@example.com"})

      assert conn |> sign_in(member) |> get(~p"/admin/audit/export") |> response(403)
    end

    test "an anonymous reader is refused", %{conn: conn} do
      assert conn |> get(~p"/admin/audit/export") |> response(403)
    end
  end

  describe "what it contains" do
    # The adapter a controller test runs on cannot stream, so the rows are
    # tested where they are made: the same batches the controller writes to the
    # socket, read back in full.
    test "one JSON object per line, with the whole event in it" do
      admin = user_fixture(%{email: "ops@example.com", display_name: "Ops Lead", role: "admin"})
      Audit.log({:user, admin}, User.audit_event_signed_in(admin))

      line = last_line(:ndjson)
      event = line |> IO.iodata_to_binary() |> Jason.decode!()

      assert event["action"] == "user.signed_in"
      assert event["actor_email"] == "ops@example.com"
      assert event["actor_name"] == "Ops Lead"
      assert is_map(event["metadata"])
    end

    test "metadata stays an object, whatever shape this event has" do
      Audit.log(
        Audit.system_actor(),
        Entry.new("sync.finished", "sync_run", 7, %{stats: %{pages: 3, unchanged: 2}})
      )

      line = last_line(:ndjson)

      assert line |> IO.iodata_to_binary() |> Jason.decode!() |> get_in(["metadata", "stats"]) ==
               %{"pages" => 3, "unchanged" => 2}
    end

    test "CSV keeps the fixed columns and puts the varying part in one cell" do
      Audit.log(
        Audit.system_actor(),
        Entry.new("sync.finished", "sync_run", 7, %{stats: %{pages: 3}})
      )

      body =
        [Export.header(:csv) | Export.batches() |> Enum.flat_map(&Export.encode(:csv, &1))]
        |> IO.iodata_to_binary()

      [header, row] = String.split(body, "\n", trim: true)

      assert header =~ "action" and header =~ "actor_email"
      assert row =~ "sync.finished"
      # Quoted and escaped: the varying part travels as JSON inside the cell.
      assert row =~ ~s(\"{\"\"stats\"\":{\"\"pages\"\":3}}\")
    end

    test "a value holding a comma or a quote is quoted, not split" do
      Audit.log(
        Audit.system_actor(),
        Entry.new("webhook.ignored", "webhook", 3, %{reason: ~s(no handler, "yet")})
      )

      body =
        [Export.header(:csv) | Export.batches() |> Enum.flat_map(&Export.encode(:csv, &1))]
        |> IO.iodata_to_binary()

      assert [_header, row] = String.split(body, "\n", trim: true)
      assert row =~ "no handler"
      assert row =~ ~s(""")
    end
  end

  # Other events may exist in the database this test runs against; the export
  # is oldest first, so the one just written is last.
  defp last_line(format) do
    Export.batches()
    |> Enum.flat_map(&Export.encode(format, &1))
    |> List.last()
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
