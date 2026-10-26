defmodule ConfluencePhxMirror.Sync.ReconcileTest do
  @moduledoc """
  What a verify pass concludes, and what it costs to conclude it.

  The two are one subject here on purpose: a pass that found the right pages by
  reading the whole site would be correct and useless.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.Reconcile
  alias ConfluencePhxMirror.UpstreamLedger

  setup do
    space = space_fixture(%{key: "ENG", name: "Engineering"})
    kept = page_fixture(space, %{confluence_id: 1001, title: "Kept"})
    gone = page_fixture(space, %{confluence_id: 1002, title: "Gone"})

    %{space: space, kept: kept, gone: gone}
  end

  test "a space the site still agrees with is never listed", %{space: space} do
    ledger(counts: %{"ENG" => %{page: 2, blogpost: 0}})

    report = reconcile()

    assert report.agreed == 1
    assert report.listed == []
    assert report.asked == 1
    assert UpstreamLedger.calls() == [{:counts, "ENG"}]
    assert Mirror.count_absent() == 0
    assert live_titles(space) == ["Gone", "Kept"]
  end

  test "a page the site no longer lists is marked absent, not trashed", %{
    space: space,
    gone: gone
  } do
    ledger(
      counts: %{"ENG" => %{page: 1, blogpost: 0}},
      page_ids: %{"ENG" => %{page: [1001], blogpost: []}}
    )

    report = reconcile()

    assert report.listed == [{space, 1}]
    assert report.absent == 1
    assert {:ok, absent} = Mirror.find_page(1002)
    refute is_nil(absent.absent_since)
    assert absent.deleted_at == nil, "nothing is trashed until an administrator says so"
    assert {:ok, still_there} = Mirror.find_page(1001)
    assert still_there.absent_since == nil
    assert gone.id
  end

  test "a page the site lists again loses its absence" do
    ledger(
      counts: %{"ENG" => %{page: 1, blogpost: 0}},
      page_ids: %{"ENG" => %{page: [1002], blogpost: []}}
    )

    reconcile()
    assert {:ok, absent} = Mirror.find_page(1001)
    refute is_nil(absent.absent_since)

    ledger(
      counts: %{"ENG" => %{page: 2, blogpost: 0}},
      page_ids: %{"ENG" => %{page: [1001, 1002], blogpost: []}}
    )

    report = reconcile()
    assert report.absent == 0
    assert {:ok, back} = Mirror.find_page(1001)
    assert back.absent_since == nil
  end

  test "a listing that names nothing marks nothing", %{space: space} do
    ledger(
      counts: %{"ENG" => %{page: 0, blogpost: 0}},
      page_ids: %{"ENG" => %{page: [], blogpost: []}}
    )

    report = reconcile()

    assert report.empty == ["ENG"]
    assert report.absent == 0
    assert live_titles(space) == ["Gone", "Kept"]
  end

  test "a source that cannot count still gets the space checked", %{space: space} do
    ledger(page_ids: %{"ENG" => %{page: [1001], blogpost: []}})

    report = reconcile(source: ConfluencePhxMirror.CountLessSource)

    assert report.agreed == 0
    assert report.listed == [{space, 1}]
    assert Enum.sort(live_titles(space)) == ["Gone", "Kept"], "absent pages stay live"
    assert [{absent, _space}] = Mirror.absent_pages()
    assert absent.title == "Gone"
  end

  test "pages and blog posts are counted apart" do
    space = Mirror.get_space_by_key("ENG")

    ledger(
      counts: %{"ENG" => %{page: 2, blogpost: 1}},
      page_ids: %{"ENG" => %{page: [1001, 1002], blogpost: [2001]}}
    )

    report = reconcile(spaces: [space])

    assert report.listed == [{space, 0}], "the counts disagreed, so the space was listed"
    assert report.absent == 0
  end

  test "a space the site refused to name is reported, not guessed at", %{space: space} do
    ledger(
      counts: %{"ENG" => %{page: 1, blogpost: 0}},
      page_ids: %{"ENG" => {:error, :unreachable}}
    )

    report = reconcile()

    assert report.failed == [{"ENG", :unreachable}]
    assert report.listed == []
    assert report.absent == 0
    assert Enum.sort(live_titles(space)) == ["Gone", "Kept"]
  end

  defp reconcile(opts \\ []) do
    Reconcile.run(Keyword.put_new(opts, :source, UpstreamLedger))
  end

  defp ledger(answers) do
    case Process.whereis(UpstreamLedger) do
      nil -> start_supervised!({UpstreamLedger, answers})
      _pid -> UpstreamLedger.configure(answers)
    end
  end

  defp live_titles(space) do
    space.id |> Mirror.list_pages() |> Enum.map(& &1.title) |> Enum.sort()
  end
end
