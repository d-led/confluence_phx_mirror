defmodule ConfluencePhxMirror.Export.SitePersonalTest do
  @moduledoc """
  A whole-site archive is a file that leaves the building, so it carries the
  spaces everybody shares and not somebody's personal one — unless the
  deployment says those are meant to travel too (`CM_EXPORT_PERSONAL_SPACES`).
  One space's own archive is not affected: asking for that one by name is not an
  accident.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.TestConfig

  setup do
    demo_snapshot!()
    # PROD stands in for somebody's own space: the export reads the space's
    # type, not its key, so what makes it personal is the fact, not the name.
    Repo.update_all(from(s in Space, where: s.key == "PROD"), set: [type: "personal"])

    :ok
  end

  test "the whole site leaves personal spaces out" do
    names = archive_names()

    assert "spaces/ENG/index.html" in names
    refute "spaces/PROD/index.html" in names
    refute Enum.any?(names, &String.starts_with?(&1, "spaces/PROD/pages/"))
  end

  test "a deployment that wants them puts them back" do
    TestConfig.put(:export_personal_spaces, true)

    assert "spaces/PROD/index.html" in archive_names()
  end

  test "one personal space is still exportable on its own" do
    personal = Repo.get_by!(Space, key: "PROD")

    names =
      Export.space_site_archive(personal, admin(), stylesheet: "")
      |> Enum.map(&elem(&1, 0))

    assert "spaces/PROD/index.html" in names
  end

  defp archive_names do
    Export.site_archive(admin(), stylesheet: "")
    |> Enum.map(&elem(&1, 0))
  end

  defp admin, do: Scope.for_user(Accounts.ensure_admin!())
end
