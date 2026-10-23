defmodule ConfluencePhxMirrorWeb.Admin.SettingsRefusal do
  @moduledoc """
  Why a settings change was refused, in a sentence an administrator can act on.

  `ConfluencePhxMirror.Settings.update/2` answers with the reason as data; this
  is the one place that turns those tuples into words. It lives in its own
  module because a screen cannot reach every reason it has to name — a failed
  audit write, a key that is not a setting, a value the form never sends — and a
  sentence nobody can exercise is a sentence nobody will notice going wrong.
  """

  @limit_keys ~w(reader.html_limit reader.api_limit reader.attachments_limit)

  @spec message(term()) :: String.t()
  def message({:invalid_value, "notifications.digest_hour_utc", _value}),
    do: "Nothing was saved: the digest hour must be a whole number from 0 to 23."

  def message({:invalid_value, "notifications.enabled", _value}),
    do: "Nothing was saved: send e-mail is on or off."

  def message({:invalid_value, key, value}) when key in @limit_keys,
    do:
      "Nothing was saved: reader limits must be whole numbers above zero (got #{inspect(value)})."

  def message({:invalid_value, key, value}),
    do: "Nothing was saved: #{inspect(value)} is not a value for #{key}."

  def message({:unknown_key, key}),
    do: "Nothing was saved: #{inspect(key)} is not a setting."

  def message({:not_audited, error}),
    do: "Nothing was saved: the change could not be recorded (#{Exception.message(error)})."

  def message({:not_stored, key, changeset}),
    do: "Nothing was saved: #{key} could not be written (#{inspect(changeset.errors)})."

  def message(reason), do: "Nothing was saved: #{inspect(reason)}"
end
