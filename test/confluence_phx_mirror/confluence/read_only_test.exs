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

  # A method handed to one of this application's own request helpers does not
  # look like a request at all. `request_json(:post, …)` reaches `Req` with a
  # variable in the method slot, so a scan for `Req.post(` cannot see it — which
  # is how the GraphQL read below arrived here without this file noticing.
  @helper_method ~r/\brequest(_json)?\(\s*:(post|put|patch|delete)\b/

  # The one file allowed to say `:post`, and the only method it may say it with:
  # Confluence's GraphQL gateway answers a query over POST and over nothing else
  # (`GET` is a 415), and a query is a read. `:put`, `:patch` and `:delete` stay
  # refused everywhere, this file included.
  @graphql_writer "lib/confluence_phx_mirror/confluence/http_source.ex"

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

  test "only the GraphQL read may tell a request helper to POST" do
    offenders =
      for path <- sources(),
          {text, line} <- lines(path),
          [_, _helper, method] <- [Regex.run(@helper_method, text)],
          not (path == @graphql_writer and method == "post"),
          do: "#{path}:#{line}: #{String.trim(text)}"

    assert offenders == [],
           """
           These hand a write to a request helper:\n\n#{Enum.join(offenders, "\n")}\n
           #{@graphql_writer} may say `:post`, and only for a GraphQL query —
           Confluence's gateway answers one over POST and nothing else.
           """

    # And it is not vacuous: the pattern does match the call it excuses, so a
    # rule that quietly stopped matching would be noticed here rather than in
    # the shape of a blind spot.
    assert Regex.match?(@helper_method, File.read!(@graphql_writer)),
           "this rule no longer matches the code it excuses, so it would not catch a new one"
  end

  test "the one POST still refuses a document that is not a query" do
    # Defence in depth, and it lives inside a private function, so it is pinned
    # by its shape: a body without a `query` string is refused, and a document
    # that names a mutation or a subscription is refused before it is sent.
    source = File.read!(@graphql_writer)

    assert source =~ "not_a_query"

    assert source =~ ~r/\bmutation\|subscription\b/,
           "the POST guard no longer refuses a document that names a mutation"
  end

  defp sources do
    for root <- @sources,
        path <- Path.wildcard("#{root}/**/*.ex"),
        do: path
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.with_index(1)
end
