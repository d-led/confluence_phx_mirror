defmodule ConfluencePhxMirror.Catalog do
  @moduledoc """
  The browsable catalogs: the space directory, the people and label indexes, and
  a space's pages, blog posts and attachments.

  Every catalog answers the same question — "which entries match what the reader
  typed?" — so they all return the same shape:

      %{items: [...], more?: boolean}

  `more?` says another page of matches exists, which is all a "load more" button
  needs and cheaper than counting thousands of rows.

  Matching is free-form: `tokens/1` splits the filter text into words and an
  entry must contain *every* one of them, so `eng arch` finds the engineering
  space's architecture pages without anyone learning a query syntax. Filtering
  and paging happen in the same SQL statement, so a catalog sends one page of
  rows to a reader whether the mirror holds ten spaces or ten thousand.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror.{Attachment, Label, Page, Space}
  alias ConfluencePhxMirror.Repo

  @default_limit 50
  @max_limit 200

  # A filter box is not a query language: ten words already narrow a catalog to
  # nothing, and the cap keeps a pathological paste from becoming thousands of
  # `where` clauses.
  @max_tokens 10

  @type page :: %{items: list(), more?: boolean()}

  # ---------------------------------------------------------------------------
  # What the reader typed
  # ---------------------------------------------------------------------------

  @doc """
  Splits filter text into the tokens every match has to contain.

  Whitespace separates tokens and case does not matter, so `Arch  ENG eng` asks
  the same question as `eng arch`. A blank filter asks for everything.
  """
  @spec tokens(term()) :: [String.t()]
  def tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.take(@max_tokens)
  end

  def tokens(_blank), do: []

  # The `LIKE` pattern for one token: the token, anywhere in the value. `%`, `_`
  # and `\` are escaped, so a reader looking for `100%` searches for a literal
  # percent sign instead of matching everything.
  defp contains(token) when is_binary(token) do
    "%" <> String.replace(token, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
  end

  # ---------------------------------------------------------------------------
  # Catalogs
  # ---------------------------------------------------------------------------

  @doc """
  A page of the space directory: every space the reader may see, with the
  counts and the latest change its card shows.
  """
  @spec spaces(Scope.t(), keyword()) :: page()
  def spaces(%Scope{} = scope, opts \\ []) do
    from(s in Space, as: :space)
    |> Authorization.restrict_spaces(scope)
    |> with_content_counts()
    |> matching(opts[:q], &space_contains/2)
    |> order_by([s], asc: s.name)
    |> page(opts)
  end

  defp space_contains(query, pattern) do
    where(
      query,
      [s],
      ilike(s.name, ^pattern) or ilike(s.key, ^pattern) or ilike(s.description, ^pattern)
    )
  end

  defp with_content_counts(query) do
    from(s in query,
      left_join: p in assoc(s, :pages),
      where: is_nil(p.deleted_at) or is_nil(p.id),
      group_by: s.id,
      select: %{
        space: s,
        pages: filter(count(p.id), p.type == "page"),
        blog_posts: filter(count(p.id), p.type == "blogpost"),
        updated_at: max(p.external_updated_at)
      }
    )
  end

  @doc """
  A page of the people directory: the authors of mirrored content, with how much
  each of them wrote.
  """
  @spec people(keyword()) :: page()
  def people(opts \\ []) do
    from(p in Page,
      where: is_nil(p.deleted_at) and not is_nil(p.author_name),
      group_by: [p.author_name, p.author_account_id],
      select: %{
        name: p.author_name,
        account_id: p.author_account_id,
        pages: count(p.id),
        updated_at: max(p.external_updated_at)
      }
    )
    |> matching(opts[:q], &author_contains/2)
    |> order_by([p], asc: p.author_name)
    |> page(opts)
  end

  defp author_contains(query, pattern) do
    where(query, [p], ilike(p.author_name, ^pattern) or ilike(p.author_account_id, ^pattern))
  end

  @doc """
  A page of the label index: every label in the mirror and how many pages carry
  it.
  """
  @spec labels(keyword()) :: page()
  def labels(opts \\ []) do
    from(l in Label,
      join: p in assoc(l, :pages),
      where: is_nil(p.deleted_at),
      group_by: l.id,
      select: %{name: l.name, pages: count(p.id)}
    )
    |> matching(opts[:q], &label_contains/2)
    |> order_by([l], asc: l.name)
    |> page(opts)
  end

  defp label_contains(query, pattern) do
    where(query, [l], ilike(l.name, ^pattern))
  end

  @doc """
  A page of one space's content.

  Options: `:type` (`"page"`, `"blogpost"` or `nil` for both) and `:sort`
  (`:title`, the default, or `:recent`).
  """
  @spec contents(Space.t(), keyword()) :: page()
  def contents(%Space{id: space_id}, opts \\ []) do
    from(p in Page,
      where: p.space_id == ^space_id and is_nil(p.deleted_at)
    )
    |> where_type(opts[:type])
    |> matching(opts[:q], &content_contains/2)
    |> order_by([p], ^order_contents(opts[:sort]))
    |> page(opts)
  end

  defp content_contains(query, pattern) do
    where(query, [p], ilike(p.title, ^pattern) or ilike(p.author_name, ^pattern))
  end

  defp where_type(query, nil), do: query
  defp where_type(query, type) when is_binary(type), do: where(query, [p], p.type == ^type)

  defp order_contents(:recent), do: [desc: :external_updated_at]
  defp order_contents(_title), do: [asc: :title]

  @doc """
  A page of one space's attachments, found by file name, media type or by the
  title of the page they hang off.
  """
  @spec attachments(Space.t(), keyword()) :: page()
  def attachments(%Space{id: space_id}, opts \\ []) do
    from(a in Attachment,
      join: p in assoc(a, :page),
      where: p.space_id == ^space_id and is_nil(p.deleted_at),
      preload: [page: :space]
    )
    |> matching(opts[:q], &attachment_contains/2)
    |> order_by([a], asc: a.filename)
    |> page(opts)
  end

  defp attachment_contains(query, pattern) do
    where(
      query,
      [a, p],
      ilike(a.filename, ^pattern) or ilike(a.media_type, ^pattern) or ilike(p.title, ^pattern)
    )
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # Applies one `where` per token, so an entry has to match all of them.
  defp matching(query, blank, _clause) when blank in [nil, ""], do: query

  defp matching(query, q, clause) do
    Enum.reduce(tokens(q), query, fn token, query -> clause.(query, contains(token)) end)
  end

  # Fetches one row more than asked for: the extra row is how `more?` knows
  # another page exists without a second counting query.
  defp page(query, opts) do
    per_page = per_page(opts[:limit])
    offset = max(opts[:offset] || 0, 0)

    rows =
      query
      |> limit(^(per_page + 1))
      |> offset(^offset)
      |> Repo.all()

    {items, rest} = Enum.split(rows, per_page)
    %{items: items, more?: rest != []}
  end

  defp per_page(nil), do: @default_limit
  defp per_page(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp per_page(_invalid), do: @default_limit
end
