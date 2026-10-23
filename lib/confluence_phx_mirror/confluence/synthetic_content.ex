defmodule ConfluencePhxMirror.Confluence.SyntheticContent do
  @moduledoc """
  Generated Confluence content, deterministic and configurable.

  A real site answers "what does a reader's page view cost when the space has a
  thousand pages?" only if such a site exists. This module writes one: spaces,
  a page tree, bodies and bylines, all derived from an index, so the same options
  always describe the same documents.

  Two callers share it, which is what keeps a benchmark honest:

    * `ConfluencePhxMirror.Confluence.SyntheticSource` feeds these documents to
      `Sync`, exactly as a Confluence site would;
    * `ConfluencePhxMirror.Synthetic` (test support) bulk-writes the rows a
      snapshot sync would store, because ten to the six pages through the
      per-page pipeline is an overnight job.

  Options (seconds caller wins, then the module configuration, then the
  defaults):

    * `:spaces` – how many spaces (default 10)
    * `:pages_per_space` – pages in each of them (default 100)
    * `:branching` – children per page in the generated tree (default 10)

  Configuration belongs next to the source module:

      config :confluence_phx_mirror, ConfluencePhxMirror.Confluence.SyntheticSource,
        spaces: 1000, pages_per_space: 1000

  Confluence ids are `(space * 100_000_000) + page`, so an id always names its
  space and page without a lookup, and nothing collides with the bundled demo
  snapshot (ids below 10_000).
  """

  @space_radix 100_000_000
  @defaults [spaces: 10, pages_per_space: 100, branching: 10]

  # Bodies are generated, not stored, so every page costs the same and a
  # benchmark measures the mirror rather than the fixture.
  @base_time ~U[2026-09-01 00:00:00Z]

  @authors [
    {"Jane Doe", "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000001"},
    {"Sam Rivera", "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000002"},
    {"Priya Nair", "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000003"},
    {"Ada Okafor", "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000004"},
    {"Luis Ferreira", "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000005"}
  ]

  @topics ~w(Architecture Operations Onboarding Runbook Decisions Roadmap
             Delivery Incidents Releases Security Tooling)

  @doc "The defaults, for a caller that wants to print them."
  def defaults, do: @defaults

  @doc """
  The options to build a document with: defaults, then module configuration,
  then whatever the caller passed.
  """
  def options(opts \\ []) do
    configured =
      Application.get_env(
        :confluence_phx_mirror,
        ConfluencePhxMirror.Confluence.SyntheticSource,
        []
      )

    @defaults
    |> Keyword.merge(configured)
    |> Keyword.merge(opts)
  end

  @doc "Space DTOs, in key order."
  def spaces(opts \\ []) do
    opts = options(opts)
    Enum.map(1..opts[:spaces], &space(&1, opts))
  end

  @doc "The key of the space at `index`, counting from one."
  def space_key(index), do: "S" <> String.pad_leading(to_string(index), 4, "0")

  @doc "The index of a space key, or `nil` when the key is not a generated one."
  def space_index("S" <> digits) do
    case Integer.parse(digits) do
      {index, ""} when index > 0 -> index
      _other -> nil
    end
  end

  def space_index(_key), do: nil

  @doc "Every page (and blog post) of a generated space, with ancestors."
  def pages(space_key, opts \\ []) do
    opts = options(opts)
    spaces = opts[:spaces]

    case space_index(space_key) do
      index when is_integer(index) and index <= spaces ->
        {:ok, Enum.map(1..opts[:pages_per_space], &page(index, &1, opts))}

      _unknown_space ->
        {:ok, []}
    end
  end

  @doc "One page by its Confluence id."
  def page(confluence_id, opts \\ [])

  def page(confluence_id, opts) when is_integer(confluence_id) do
    opts = options(opts)
    space_index = div(confluence_id, @space_radix)
    page_index = confluence_id - space_index * @space_radix

    if space_index in 1..opts[:spaces] and page_index in 1..opts[:pages_per_space] do
      {:ok, page(space_index, page_index, opts)}
    else
      {:error, :not_found}
    end
  end

  def page(_confluence_id, _opts), do: {:error, :not_found}

  @doc "Confluence id of the `page_index`-th page of the `space_index`-th space."
  def page_id(space_index, page_index), do: space_index * @space_radix + page_index

  @doc """
  The mirror's URL path for a generated page.

  The slug comes from `Mirror.Page.slugify/1` — the same function the sync uses
  to store it — so a harness can open the canonical path instead of measuring
  the redirect from the slugless one.
  """
  def page_path(space_index, page_index) do
    id = page_id(space_index, page_index)

    "/spaces/#{space_key(space_index)}/pages/#{id}/" <>
      ConfluencePhxMirror.Mirror.Page.slugify(title(page_index))
  end

  defp space(index, opts) do
    key = space_key(index)

    %{
      key: key,
      name: "Synthetic Space #{String.pad_leading(to_string(index), 4, "0")}",
      type: "global",
      description: "Generated content for scale work: space #{index} of #{opts[:spaces]}.",
      homepage_id: page_id(index, 1),
      url: "https://synthetic.invalid/wiki/spaces/#{key}"
    }
  end

  defp page(space_index, page_index, opts) do
    title = title(page_index)
    updated_at = timestamp(space_index, page_index)
    {author, account_id} = Enum.at(@authors, rem(space_index + page_index, length(@authors)))
    key = space_key(space_index)
    id = page_id(space_index, page_index)

    %{
      id: id,
      type: type(page_index),
      status: status(page_index),
      title: title,
      space_key: key,
      parent_id: parent_id(space_index, page_index, opts[:branching]),
      ancestors: ancestors(space_index, page_index, opts[:branching]),
      version: %{
        number: rem(page_index, 20) + 1,
        message: "Generated update #{rem(page_index, 20) + 1}",
        when: updated_at,
        by: %{display_name: author, account_id: account_id}
      },
      body: %{
        storage: body(key, title, page_index),
        export_view: body(key, title, page_index)
      },
      labels: ["topic-#{rem(page_index, 7)}", "kind-#{rem(page_index, 3)}"],
      url: "https://synthetic.invalid/wiki/spaces/#{key}/pages/#{id}/#{slug(title)}",
      created_at: @base_time,
      updated_at: updated_at
    }
  end

  # A readable sibling order: the index is padded so the sidebar sorts the same
  # way the generator counts.
  defp title(page_index) do
    topic = Enum.at(@topics, rem(page_index, length(@topics)))
    "Page #{String.pad_leading(to_string(page_index), 4, "0")} — #{topic}"
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  # Confluence keeps blog posts out of the page tree; a generated space holds
  # some as well so the tree and the blog catalog are both exercised.
  defp type(page_index) when page_index > 1 and rem(page_index, 50) == 0, do: "blogpost"
  defp type(_page_index), do: "page"

  defp status(page_index) when page_index > 1 and rem(page_index, 97) == 0, do: "archived"
  defp status(_page_index), do: "current"

  # A complete tree with `branching` children per page: page 1 is the root,
  # page `div(index - 2, branching) + 1` its parent.
  defp parent_id(_space_index, 1, _branching), do: nil

  defp parent_id(space_index, page_index, branching),
    do: page_id(space_index, div(page_index - 2, branching) + 1)

  defp ancestors(_space_index, 1, _branching), do: []

  defp ancestors(space_index, page_index, branching) do
    page_index
    |> ancestor_indexes(branching)
    |> Enum.map(&page_id(space_index, &1))
  end

  defp ancestor_indexes(1, _branching), do: []

  defp ancestor_indexes(page_index, branching) do
    parent = div(page_index - 2, branching) + 1
    ancestor_indexes(parent, branching) ++ [parent]
  end

  defp timestamp(space_index, page_index) do
    DateTime.add(@base_time, (space_index * 1_000 + page_index) * 60, :second)
  end

  # Roughly the size of a Confluence page that carries prose: headings, a table
  # and some code. The mirror renders `body_export` as-is, so what it costs to
  # send is what the page really costs.
  defp body(key, title, page_index) do
    topic = Enum.at(@topics, rem(page_index, length(@topics)))

    """
    <h1>#{title}</h1>
    <p>This page belongs to #{key} and describes how the team works on #{topic}.
    It is generated content: the shape of a mirrored page, at whatever scale the
    harness asks for, without pretending to be anyone's documentation.</p>
    <h2 id="context">Context</h2>
    <p>Readers arrive here from the sidebar, from search, or from another page's
    link. Every one of those entry points renders this page through the same
    controller, so the cost of a read is one page fetch, its breadcrumbs, its
    children, its attachments, its comments and its backlinks.</p>
    <table class="confluenceTable"><tbody>
      <tr><th class="confluenceTh">Field</th><th class="confluenceTh">Value</th></tr>
      <tr><td class="confluenceTd">Space</td><td class="confluenceTd">#{key}</td></tr>
      <tr><td class="confluenceTd">Page</td><td class="confluenceTd">#{page_index}</td></tr>
      <tr><td class="confluenceTd">Owner</td><td class="confluenceTd">Team #{rem(page_index, 12)}</td></tr>
    </tbody></table>
    <h2 id="decisions">Decisions</h2>
    <ul>
      <li>Keep the mirror read-only; content arrives through a sync.</li>
      <li>Answer a read with the rows the page needs, not the whole space.</li>
      <li>Page the catalog in the database; never in memory.</li>
    </ul>
    <div class="code panel"><div class="codeContent panelContent"><pre
    class="syntaxhighlighter"><code>mix confluence.sync --mode=incremental</code></pre></div></div>
    <blockquote><p>Generated for scale measurements; not a real document.</p></blockquote>
    """
  end
end
