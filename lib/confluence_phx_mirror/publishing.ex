defmodule ConfluencePhxMirror.Publishing do
  @moduledoc """
  What this deployment publishes, and to whom.

  A mirror behind its proxy publishes to the people it admitted: everyone who
  arrives has an identity, and `Authorization` replays the site's permissions for
  them. A mirror put on the internet as a documentation site is a different
  deployment, and it says so with settings, all off by default:

      CM_PUBLIC_SITE=true             a stranger is a reader
      CM_PUBLIC_SPACES=ENG,OPS        …of these spaces only
      CM_ANONYMIZE_CONTRIBUTORS=true  bylines are not published
      CM_EXCLUDE_COMMENTS=true        comments are not published

  The first is the one that changes an answer rather than a screen. Anonymous
  readers already exist — the sync mirrors Confluence's `anonymousAccess` as the
  `anonymous` subject, and `Scope.for_user(nil)` is that reader — but one rule
  reads a space with **no synced permission rows as open**, which is fair while
  the audience had to be admitted and is not fair once everyone includes the
  internet: a permissions read that failed, or a space the sync never stored,
  looks exactly like "everyone". `Authorization` therefore asks
  `public_site?/0` before it reads silence as openness.

  ## Public by the space, not by the site

  A mirror with two audiences — most spaces internal, a few meant for the world
  — names the public ones in `CM_PUBLIC_SPACES`, and in nothing else: no
  catalogue entry, no admin screen, no per-space column. It is a deploy, because
  the one mistake here is a leak. The list **narrows** `CM_PUBLIC_SITE`: a
  stranger is a reader of those spaces, the synced permissions still decide
  inside them, and a page outside the list gets the 404 an unknown page gets.
  Unset keeps the site-wide meaning, so no running deployment changes silently.

  **A public page names nobody, and that is the default rather than a second
  flag.** Forgetting `CM_ANONYMIZE_CONTRIBUTORS` would publish the identities of
  exactly the pages meant for the world, so public ⇒ anonymised. A reader with
  an account reading the same page keeps what they always saw — the question is
  per reader *and* per page, which is what `identities?/1` answers. Two things
  cannot be per reader and are decided from the page's space instead: the stored
  body (`body_export`), rendered once at sync time and served to everybody
  (`identities_in_space?/1`), and files that leave the building (`Export`, the
  Markdown and static exports), which are somebody's copy the moment they are
  written.

  The other two settings are content, and each is one seam: `byline/1` where a
  name is drawn, and `exclude_comments?/0` where comments are read — page view,
  search, exports and the API all go through them, so there is no surface left
  that publishes what the deployment said it does not.
  """

  alias ConfluencePhxMirror.Accounts.Scope

  @app :confluence_phx_mirror

  @doc """
  Whether the reader paths are served without a sign-in.

  Read where the *rule* would otherwise be too generous (a space with no synced
  permissions) and where the shell would point at a sign-in nobody needs.
  """
  @spec public_site?() :: boolean()
  def public_site?, do: flag(:public_site)

  @doc """
  The spaces a stranger may read, normalised as Confluence keys.

  Empty means "no list": a public site, if this is one, stays all-or-nothing.
  """
  @spec public_spaces() :: [String.t()]
  def public_spaces do
    @app
    |> Application.get_env(:public_spaces, [])
    |> Enum.map(&normalise_key/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc "Whether `key` is one of the spaces a stranger may read."
  @spec public_space?(String.t() | nil) :: boolean()
  def public_space?(key), do: normalise_key(key) in public_spaces()

  @doc """
  One line for the boot log: what this deployment publishes, and to whom.

  A wrong key in the list is the mistake this setting exists to make hard, so
  the resolved list is named on every start rather than left to be inferred from
  what a stranger happens to see.
  """
  @spec describe() :: String.t()
  def describe do
    case {public_site?(), public_spaces()} do
      {false, []} ->
        "publishing to admitted readers only"

      {true, []} ->
        "public site: a stranger reads every space the permissions leave open"

      {false, keys} ->
        "public spaces #{Enum.join(keys, ", ")} — inert without CM_PUBLIC_SITE"

      {true, keys} ->
        "public spaces #{Enum.join(keys, ", ")}: a stranger reads those, and they are anonymised"
    end
  end

  @doc "Whether contributor names are published."
  @spec anonymise_contributors?() :: boolean()
  def anonymise_contributors?, do: flag(:anonymize_contributors)

  @doc "Whether comments are published."
  @spec exclude_comments?() :: boolean()
  def exclude_comments?, do: flag(:exclude_comments)

  @doc """
  Whether `scope` may be shown who wrote, commented or is reading.

  False for a stranger on a public deployment — a page they may open names
  nobody — and for everybody on a deployment that publishes no names. A reader
  with an account is not a stranger: the same page keeps its bylines for them.
  """
  @spec identities?(Scope.t()) :: boolean()
  def identities?(%Scope{} = scope),
    do: not anonymise_contributors?() and not stranger?(scope)

  @doc """
  Whether the one stored copy of a space's bodies may name people.

  A body is rendered once, at sync time, and served to every reader, so a space
  a stranger can reach has to be stored in the stranger's shape.
  """
  @spec identities_in_space?(String.t() | nil) :: boolean()
  def identities_in_space?(space_key),
    do: not anonymise_contributors?() and not public_space?(space_key)

  @doc """
  Whether a stranger may reach `space_key` without signing in.

  The same question `identities_in_space?/1` asks, and the same reason for
  asking it at sync time: what a renderer bakes into a body is shown to every
  reader of that body. A widget connector is the case that made this its own
  function — one third-party frame in a body a stranger opens is a stranger's
  browser talking to a third party nobody negotiated with.
  """
  @spec stranger_reachable?(String.t() | nil) :: boolean()
  def stranger_reachable?(space_key), do: public_site?() or public_space?(space_key)

  @doc """
  A byline as this deployment publishes it: the name, or `nil` for no name.

  Every surface that draws an author asks this, so "we do not publish names"
  is one setting rather than a list of pages somebody remembered.
  """
  @spec byline(term()) :: String.t() | nil
  def byline(name) when is_binary(name) and name != "" do
    if anonymise_contributors?(), do: nil, else: name
  end

  def byline(_name), do: nil

  @doc """
  The same byline for one reader, wherever the name is drawn per request.

  Use `byline/1` where there is no reader — a file written for nobody in
  particular — and `byline/2` for a page, a comment or a list somebody is
  looking at. The boolean form is the answer to `identities?/1`, for a component
  that was handed the decision rather than the reader.
  """
  @spec byline(term(), Scope.t() | boolean()) :: String.t() | nil
  def byline(name, %Scope{} = scope) do
    byline(name, identities?(scope))
  end

  def byline(name, identities?) when is_boolean(identities?) do
    if identities?, do: byline(name)
  end

  # A stranger is the reader with no account on a public deployment: the same
  # question `Authorization` asks before it reads silence as openness.
  defp stranger?(%Scope{} = scope), do: public_site?() and not Scope.signed_in?(scope)

  defp normalise_key(key) when is_binary(key), do: key |> String.trim() |> String.upcase()
  defp normalise_key(_key), do: ""

  defp flag(key), do: Application.get_env(@app, key, false) == true
end
