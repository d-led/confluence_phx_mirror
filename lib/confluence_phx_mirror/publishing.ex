defmodule ConfluencePhxMirror.Publishing do
  @moduledoc """
  What this deployment publishes, and to whom.

  A mirror behind its proxy publishes to the people it admitted: everyone who
  arrives has an identity, and `Authorization` replays the site's permissions for
  them. A mirror put on the internet as a documentation site is a different
  deployment, and it says so with three settings, all off by default:

      CM_PUBLIC_SITE=true             a stranger is a reader
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

  The other two are content, and each is one seam: `byline/1` where a name is
  drawn, and `exclude_comments?/0` where comments are read — page view, search,
  exports and the API all go through them, so there is no surface left that
  publishes what the deployment said it does not.
  """

  @app :confluence_phx_mirror

  @doc """
  Whether the reader paths are served without a sign-in.

  Read where the *rule* would otherwise be too generous (a space with no synced
  permissions) and where the shell would point at a sign-in nobody needs.
  """
  @spec public_site?() :: boolean()
  def public_site?, do: flag(:public_site)

  @doc "Whether contributor names are published."
  @spec anonymise_contributors?() :: boolean()
  def anonymise_contributors?, do: flag(:anonymize_contributors)

  @doc "Whether comments are published."
  @spec exclude_comments?() :: boolean()
  def exclude_comments?, do: flag(:exclude_comments)

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

  defp flag(key), do: Application.get_env(@app, key, false) == true
end
