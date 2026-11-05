defmodule ConfluencePhxMirror.Confluence.ReadOnlyTest do
  @moduledoc """
  The mirror reads a site; it never writes to one.

  That is not a convention anyone has to remember — it is what the code has to be
  unable to say. This test reads the application's own sources and fails on a
  request that is not a `GET`, so a future "just this once" seeding script, a
  tidy-up that posts a comment back, or a copy-pasted upload cannot land quietly.

  The one exception is named: `Mix.Tasks.Confluence.Webhook` posts to *this
  mirror's* `/webhooks/confluence`, which is our own intake — a delivery from a
  script, not a change to Confluence.
  """

  use ExUnit.Case, async: true

  @sources ~w(lib lib_desktop)

  # Files allowed to make a non-GET request, and why: they talk to this
  # application, never to the site it mirrors.
  @allowed %{"lib/mix/tasks/confluence.webhook.ex" => "posts to our own webhook intake"}

  @write_call ~r/\bReq\.(post|put|patch|delete)!?\(/
  @write_method ~r/method:\s*:(post|put|patch|delete)\b/

  test "no module in the application sends a non-GET request" do
    offenders =
      for path <- sources(),
          path not in Map.keys(@allowed),
          {text, line} <- lines(path),
          Regex.match?(@write_call, text) or Regex.match?(@write_method, text),
          do: "#{path}:#{line}: #{String.trim(text)}"

    assert offenders == [],
           """
           These send something other than a GET:\n\n#{Enum.join(offenders, "\n")}\n

           The mirror must not write to Confluence. If this is a call to our own
           screens, add the file to @allowed with the reason.
           """
  end

  test "the exception is still a file that exists, and still only for our own intake" do
    # An allowlist that outlives its file is an allowlist that hides the next one.
    for {path, reason} <- @allowed do
      assert File.exists?(path), "#{path} is excused (#{reason}) but does not exist"

      assert path |> File.read!() |> String.contains?("/webhooks/"),
             "#{path} is excused but no longer posts to our own webhook intake"
    end
  end

  defp sources do
    for root <- @sources,
        path <- Path.wildcard("#{root}/**/*.ex"),
        do: path
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.with_index(1)
end
