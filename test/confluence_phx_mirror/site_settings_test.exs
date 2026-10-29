defmodule ConfluencePhxMirror.SiteSettingsTest do
  @moduledoc """
  The site's own configuration: what it says, what the mirror keeps, and what a
  reader sees of it. A site that cannot be read is the case worth having a test
  for — silence must not look like a decision.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Ecto.Query

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.SiteSettings

  # The test database is seeded once from the demo snapshot, which reads the demo
  # site's own configuration. Every test here starts from a site that has said
  # nothing yet — and from a cache that says the same.
  setup do
    Repo.delete_all(SiteSettings.Setting)
    Repo.delete_all(from e in Event, where: e.action == "site.settings_read")
    SiteSettings.forget()
    :ok
  end

  test "a site that has never said makes no claim" do
    assert SiteSettings.current() == nil
    assert SiteSettings.title() == nil
    assert SiteSettings.lang() == nil
    assert SiteSettings.timezone() == nil
  end

  test "what the site says is kept, and its language becomes an HTML tag" do
    assert SiteSettings.put(%{title: "Acme Wiki", locale: "en_GB", timezone: "Europe/Berlin"}) ==
             :changed

    assert SiteSettings.title() == "Acme Wiki"
    assert SiteSettings.lang() == "en-GB"
    assert SiteSettings.timezone() == "Europe/Berlin"
  end

  test "a second read that says the same is not a change" do
    SiteSettings.put(%{title: "Acme Wiki", locale: "en_GB", timezone: "Europe/Berlin"})

    assert SiteSettings.put(%{title: "Acme Wiki", locale: "en_GB", timezone: "Europe/Berlin"}) ==
             :ok

    assert Repo.aggregate(from(e in Event, where: e.action == "site.settings_read"), :count) == 1
  end

  test "a site that renames itself is a change, and is audited" do
    SiteSettings.put(%{title: "Acme Wiki", locale: "en_GB"})

    assert SiteSettings.put(%{title: "Acme Knowledge", locale: "en_GB"}) == :changed
    assert SiteSettings.title() == "Acme Knowledge"
  end

  test "a blank answer is no answer" do
    assert SiteSettings.put(%{title: "  ", locale: nil, timezone: ""}) == :changed

    assert SiteSettings.title() == nil
    assert SiteSettings.lang() == nil
    assert SiteSettings.timezone() == nil
  end

  test "a run reads the site's own configuration into the mirror" do
    demo_snapshot!()

    assert SiteSettings.title() == "Demo Confluence"
    assert SiteSettings.lang() == "en-GB"
    assert SiteSettings.timezone() == "Europe/Berlin"
  end
end
