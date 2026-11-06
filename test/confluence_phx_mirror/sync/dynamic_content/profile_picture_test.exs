defmodule ConfluencePhxMirror.Sync.DynamicContent.ProfilePictureTest do
  @moduledoc """
  *Profile picture* is one person's face, served from the mirror's own blob
  store, and the way to their page.

  `export_view` leaves a picture of the macro, so the page's storage is the only
  place the person is named. A reader who may not be shown names gets neither
  the face nor the link, because the body is rendered once for every reader.
  """

  # Sequential: a published space is the application environment, shared by the
  # whole suite — see `TestConfig`.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent
  alias ConfluencePhxMirror.TestConfig

  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}
  @marker ~s(<div class="mirror-macro" data-macro="profile-picture" data-user="acc-jane"></div>)

  test "shows the picture the mirror keeps, and links to the person" do
    held_person()

    html = expand()

    assert Floki.find(
             Floki.parse_fragment!(html),
             "a[href='/people/acc-jane'] img[src='/people/acc-jane/avatar']"
           ) !=
             []
  end

  # The people route answers 404 for somebody the mirror never saw: the macro says
  # so rather than drawing a face and a link to nowhere.
  test "a person the mirror does not hold is named, not linked" do
    html = expand()

    assert html =~ "not in the mirror, or not readable here"
    refute html =~ "/people/"
    refute html =~ "<img"
  end

  # The avatar route answers a stranger with a 404 — a face is a name spelled in
  # pixels — and this body is stored once and served to everybody.
  test "a space the deployment publishes names nobody, face included" do
    TestConfig.put(:public_spaces, ["ENG"])
    held_person()

    html = expand()

    refute html =~ "/people/"
    refute html =~ "<img"
  end

  test "a macro that names no person says so" do
    assert expand(~s(<div class="mirror-macro" data-macro="profile-picture"></div>)) =~
             "names no person"
  end

  defp held_person,
    do: StubContent.script(authored: {:ok, %{name: "Jane", pages: []}})

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})
end
