defmodule ConfluencePhxMirror.Sync.RendererTranslationTest do
  @moduledoc """
  Every address the site writes for something this mirror *holds* is a link
  inside the mirror, and an address for something it does not hold keeps the
  site's.

  One body carries every spelling the site is known to write — a page by its path
  and by its id, a space and its overview and its legacy address, the space
  directory, the activity feed, a person and a person's space, a label, a file —
  so a spelling the rules do not answer fails as an address that still names the
  site, named by the entry it came from.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.{Page, Space}
  alias ConfluencePhxMirror.Sync.Renderer

  @site "https://dled.atlassian.net"

  # Each names something the lookups below hold; otherwise the test would be
  # asserting the opposite rule.
  @spellings [
    {"a page by its path", "#{@site}/wiki/spaces/ENG/pages/101/Architecture+Overview"},
    {"a page by its id", "#{@site}/pages/viewpage.action?pageId=101"},
    {"a page as its own address", "/wiki/spaces/ENG/pages/100/Home"},
    {"a space", "#{@site}/wiki/spaces/PROD"},
    {"a space's overview", "#{@site}/wiki/spaces/PROD/overview"},
    {"a space's legacy address", "#{@site}/wiki/display/PROD"},
    {"the space directory", "#{@site}/wiki/spaces/browsespace.action"},
    {"the activity feed", "#{@site}/wiki/plugins/recently-updated/changes.action"},
    {"a person", "#{@site}/wiki/people/557058:abc"},
    {"a person's space", "#{@site}/wiki/display/~557058%3Aabc"},
    {"a label", "#{@site}/wiki/labels/runbook"},
    {"a file of the page", "#{@site}/wiki/download/attachments/100/diagram.svg"}
  ]

  test "every spelling of something this mirror holds is a link here" do
    rendered = Renderer.render(links(@spellings), context()).html

    assert off_site(rendered) == [],
           "these still name the site: #{inspect(off_site(rendered))}"
  end

  # A link to a page nobody mirrored is honest; a link to nowhere is not.
  test "an address naming something the mirror does not hold keeps the site's" do
    html =
      links([
        {"a page nobody mirrored", "#{@site}/pages/viewpage.action?pageId=999"},
        {"a space nobody mirrored", "#{@site}/wiki/spaces/ELSEWHERE"},
        {"a person the mirror never saw", "#{@site}/wiki/people/557058:nobody"}
      ])

    assert off_site(Renderer.render(html, context()).html) == [
             "#{@site}/pages/viewpage.action?pageId=999",
             "#{@site}/wiki/spaces/ELSEWHERE",
             "#{@site}/wiki/people/557058:nobody"
           ]
  end

  defp links(spellings) do
    Enum.map_join(spellings, fn {name, href} -> ~s(<a href="#{href}">#{name}</a>) end)
  end

  defp off_site(html), do: html |> hrefs() |> Enum.filter(&String.contains?(&1, @site))

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("a[href]")
    |> Floki.attribute("href")
  end

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        page: %Page{confluence_id: 100, title: "Home"},
        space_key: "ENG",
        base_url: @site,
        pages: %{
          100 => %{space_key: "ENG", confluence_id: 100, slug: "home"},
          101 => %{space_key: "ENG", confluence_id: 101, slug: "Architecture+Overview"}
        },
        attachments: %{
          {100, "diagram.svg"} => %{
            confluence_id: 9001,
            page_confluence_id: 100,
            space_key: "ENG",
            filename: "diagram.svg"
          }
        },
        space_lookup: &space_named/1,
        person_lookup: &person_named/1
      },
      extra
    )
  end

  defp space_named(key) when is_binary(key) do
    if String.upcase(key) == "PROD", do: %Space{key: "PROD"}
  end

  defp person_named(account_id) when is_binary(account_id) do
    if account_id == "557058:abc", do: %{account_id: account_id}
  end
end
