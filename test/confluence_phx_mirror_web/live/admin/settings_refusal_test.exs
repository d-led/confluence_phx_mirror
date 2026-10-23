defmodule ConfluencePhxMirrorWeb.Admin.SettingsRefusalTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Admin.SettingsRefusal

  test "an hour that cannot exist is named, and its range given" do
    assert SettingsRefusal.message({:invalid_value, "notifications.digest_hour_utc", "24"}) =~
             "the digest hour must be a whole number from 0 to 23"
  end

  test "an on/off switch that arrived as something else says it is on or off" do
    assert SettingsRefusal.message({:invalid_value, "notifications.enabled", "maybe"}) =~
             "send e-mail is on or off"
  end

  test "a reader limit that is not a number is refused as a limit, not as a value" do
    assert SettingsRefusal.message({:invalid_value, "reader.api_limit", "lots"}) =~
             "reader limits must be whole numbers above zero (got \"lots\")"
  end

  test "any other value names both the value and the setting" do
    assert SettingsRefusal.message({:invalid_value, "theme", "plaid"}) =~
             "\"plaid\" is not a value for theme"
  end

  test "a key that is not a setting is quoted, so a typo is visible" do
    assert SettingsRefusal.message({:unknown_key, "reader.html_limt"}) =~
             "\"reader.html_limt\" is not a setting"
  end

  test "a change that could not be recorded carries the reason it failed" do
    assert SettingsRefusal.message({:not_audited, %RuntimeError{message: "audit table gone"}}) =~
             "could not be recorded (audit table gone)"
  end

  test "a change that could not be stored quotes what the changeset objected to" do
    changeset = %{errors: [value: {"is invalid", []}]}

    assert SettingsRefusal.message({:not_stored, "theme", changeset}) =~
             "theme could not be written ([value: {\"is invalid\", []}])"
  end

  test "a reason nobody anticipated is at least shown" do
    assert SettingsRefusal.message(:something_new) =~ ":something_new"
  end
end
