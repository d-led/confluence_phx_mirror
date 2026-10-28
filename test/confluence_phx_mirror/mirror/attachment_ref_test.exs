defmodule ConfluencePhxMirror.Mirror.AttachmentRefTest do
  @moduledoc """
  A download URL names the content a file hangs off, and a page may link a file
  it does not own. Rendering that page needs an answer about attachments
  elsewhere — or the link leaves the mirror for no better reason than ownership.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror

  setup do
    eng = space_fixture(%{key: "ENG"})
    owner = page_fixture(eng, %{confluence_id: 1002, title: "Architecture Overview"})

    attachment_fixture(owner, %{confluence_id: "9001", filename: "diagram.svg"})

    %{owner: owner, space: eng}
  end

  test "answers for a file another page owns, with what a reader route needs" do
    assert %{confluence_id: "9001", page_confluence_id: 1002, space_key: "ENG"} =
             Mirror.attachment_ref(1002, "diagram.svg")
  end

  test "a file the mirror does not hold has no answer" do
    assert Mirror.attachment_ref(1002, "missing.png") == nil
    assert Mirror.attachment_ref(4242, "diagram.svg") == nil
  end

  test "a file on a trashed page is not served from the trash", %{owner: owner, space: space} do
    {:ok, _} = ConfluencePhxMirror.Trash.trash_page({:system, "test"}, owner, space)

    assert Mirror.attachment_ref(1002, "diagram.svg") == nil
  end
end
