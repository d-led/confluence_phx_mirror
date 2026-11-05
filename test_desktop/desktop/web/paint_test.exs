defmodule ConfluencePhxMirror.Desktop.Web.PaintTest do
  @moduledoc """
  The one claim only a window can make: what a screen it drew looks like.

  Every other test in this repository asks a server questions, and a server that
  serves HTML has not drawn anything — which is how a window that judged its own
  splash page a foreign link passed the whole suite while opening a console and a
  browser instead of the tool. The tool's pages therefore report the document
  they built, and this is what that report means.

  A path alone would be too little to be worth having: `/` is the setup form on a
  fresh workspace and the mirror's home on a configured one, so "the window drew
  `/`" is true of a window showing nothing anybody could type into.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias ConfluencePhxMirror.Desktop.Web.{Dispatch, Page, Paint}

  @setup_form %{
    "path" => "/",
    "title" => "Set up the mirror",
    "heading" => "Connect to Confluence",
    "fields" => "site,email,secret,root",
    "button" => "Save and continue"
  }

  setup do
    Paint.forget()
    :ok
  end

  test "a window that has drawn nothing says so, and says it differently from a missing page" do
    conn = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert conn.status == 503
    assert conn.resp_body =~ "no window has drawn a screen yet"
  end

  test "the report names the screen, what it says, and the boxes on it" do
    assert painted(@setup_form).status == 204

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.status == 200
    assert report.resp_body =~ "painted / at"
    assert report.resp_body =~ "title: Set up the mirror"
    assert report.resp_body =~ "heading: Connect to Confluence"
    assert report.resp_body =~ "fields: site,email,secret,root"
    assert report.resp_body =~ "button: Save and continue"
  end

  test "a screen with nothing to type into is reported as such" do
    painted(%{@setup_form | "fields" => "", "button" => ""})

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.resp_body =~ "fields: \n"
    assert report.resp_body =~ "button: \n"
  end

  test "the last screen a window drew is the one reported" do
    painted(@setup_form)
    painted(%{@setup_form | "path" => "/__tool/spaces"})

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.resp_body =~ "painted /__tool/spaces at"
  end

  test "a window's words are clamped, not carried whole into a report" do
    long = String.duplicate("x", 500)

    painted(%{@setup_form | "heading" => long})

    report = Dispatch.call(conn("GET", "/__tool/painted"), [])

    assert report.resp_body =~ "heading: " <> String.duplicate("x", 200) <> "\n"
    refute report.resp_body =~ long
  end

  test "the first screen a window lands on reports what it sees, not where it is" do
    # A launch with nothing configured lands on the setup form, so that is the
    # page a smoke test of a packaged build reads its report from — and the boxes
    # a person types into are what it has to name.
    setup = Page.setup(%{})

    assert setup =~ ~s|document.querySelectorAll("input, select, textarea")|
    assert setup =~ ~s|"/__tool/painted?" + query|
  end

  test "the screen behind the account menu reports the same way" do
    assert Page.home() =~ ~s|"/__tool/painted?" + query|
  end

  # A report as the window sends it: query string, one key per fact.
  defp painted(form) do
    query = form |> Enum.to_list() |> URI.encode_query()

    Dispatch.call(conn("POST", "/__tool/painted?" <> query), [])
  end
end
