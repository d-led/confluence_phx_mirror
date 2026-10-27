defmodule ConfluencePhxMirrorWeb.AdminPagingTest do
  @moduledoc """
  A page number is whatever the URL says, so the reader has to survive a link
  that names none.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Admin.Paging

  describe "a page named in the query string" do
    test "is the number it says" do
      assert Paging.page_number("3") == 3
      assert Paging.page_number(4) == 4
    end

    test "is the first page when it names nothing usable" do
      for value <- [nil, "", "0", "-2", "lots", "3abc", "3 ", 0, -1, ["3"], %{}] do
        assert Paging.page_number(value) == 1, "#{inspect(value)} should be page 1"
      end
    end
  end

  describe "how many pages a result set makes" do
    test "is never fewer than one, so a pager always has a page to show" do
      assert Paging.page_count(0, 25) == 1
      assert Paging.page_count(1, 25) == 1
      assert Paging.page_count(25, 25) == 1
      assert Paging.page_count(26, 25) == 2
    end
  end
end
