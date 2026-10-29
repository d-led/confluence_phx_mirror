defmodule ConfluencePhxMirror.Confluence.Source do
  @moduledoc """
  A source of Confluence content.

  The sync pipeline only talks to this behaviour, which keeps it independent of
  *how* content arrives:

    * `ConfluencePhxMirror.Confluence.HttpSource` – Confluence REST API
    * `ConfluencePhxMirror.Confluence.DemoSource` – bundled sample snapshot

  All functions return plain maps ("DTOs") shaped like the Confluence REST API,
  so both sources exercise exactly the same ingestion code.
  ## Page DTO

      %{
        id: 1002,
        type: "page" | "blogpost",
        status: "current" | "draft" | "archived",
        subtype: "live" | nil,
        title: "Architecture Overview",
        space_key: "ENG",
        parent_id: 1001 | nil,
        ancestors: [1000, 1001],
        version: %{number: 7, message: "...", when: DateTime.t(), by: %{display_name: "...", account_id: "..."}},
        body: %{storage: "<p>...</p>", export_view: "<p>...</p>"},
        labels: ["architecture", "howto"],
        url: "https://site.atlassian.net/wiki/spaces/ENG/pages/1002/...",
        created_at: DateTime.t(),
        updated_at: DateTime.t()
      }

  ## Space DTO

      %{key: "ENG", name: "Engineering", type: "global", description: "...",
        homepage_id: 1000, url: "https://site.atlassian.net/wiki/spaces/ENG",
        icon: %{path: "/download/attachments/1/ENG-default"} | nil,
        labels: ["engineering"]}

  `icon.path` is the space's icon as Confluence addresses it; the sync asks for
  the bytes with `space_icon/2`. `labels` are the space's own labels — its
  categories — not the labels of its pages. A source without icons leaves the
  key out.

  ## Attachment DTO

      %{id: 9001, page_id: 1002, filename: "diagram.svg",
        media_type: "image/svg+xml", byte_size: 1234, version: 2,
        download_url: "/download/attachments/1002/diagram.svg",
        updated_at: DateTime.t(), comment_id: 3001 | nil}

  `page_id` is the page the mirror stores the file under; `comment_id` is set
  when the file belongs to a comment rather than the page itself.

  ## Comment DTO

      %{id: 3001, page_id: 1001, parent_id: nil, author: "Jane Doe",
        author_account_id: "557058:...", body_export: "<p>...</p>",
        version_number: 2, created_at: DateTime.t(), updated_at: DateTime.t(),
        url: "...", attachments: [attachment()]}

  A comment is content with a version of its own, and it can carry files of its
  own: a screenshot pasted into a reply belongs to the comment. `attachments`
  is therefore always present, empty when the comment has none.

  ## Permission DTOs

      # page read restriction
      %{subject_type: "user" | "group", subject_key: "jane@acme.com" | "confluence-users"}

      # space read permission
      %{operation: "read", subject_type: "user" | "group" | "authenticated" | "anonymous",
        subject_key: "jane@acme.com" | "confluence-users" | nil}
  """

  @type page :: map()
  @type space :: map()
  @type attachment :: map()
  @type comment :: map()
  @type restriction :: %{subject_type: String.t(), subject_key: String.t()}
  @type permission :: %{
          operation: String.t(),
          subject_type: String.t(),
          subject_key: String.t() | nil
        }
  @type group_member :: %{
          email: String.t() | nil,
          account_id: String.t() | nil,
          display_name: String.t() | nil
        }

  @type account_status :: %{
          account_status: String.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil
        }

  @doc "Human readable source name, recorded on every sync run."
  @callback name() :: String.t()

  @doc """
  The address of the site's wiki root, when it has one.

  This is the URL a reader opens to see the original site rather than its
  mirror, so every screen that says where the content came from can link to it.
  A bundled snapshot has no upstream and returns `nil`.
  """
  @callback web_url() :: String.t() | nil

  @doc """
  Where the content really comes from.

  `:demo` is the bundled sample snapshot that ships with the mirror; `:live` is
  a real Confluence site read over its REST API. Every screen that talks about
  syncing must say which of the two it is showing — demo data is a fixture, not
  a mirrored site.
  """
  @callback kind() :: :demo | :live

  @doc "All spaces the mirror is configured to import."
  @callback spaces(keyword()) :: {:ok, [space()]} | {:error, term()}

  @doc "All pages (and blog posts) of one space, with bodies expanded."
  @callback pages(space_key :: String.t(), keyword()) :: {:ok, [page()]} | {:error, term()}

  @doc "One page by its Confluence id."
  @callback page(confluence_id :: integer(), keyword()) :: {:ok, page()} | {:error, term()}

  @doc "Comments of a page, including replies."
  @callback comments(confluence_id :: integer(), keyword()) ::
              {:ok, [comment()]} | {:error, term()}
  @doc "Attachment metadata of a page."
  @callback attachments(confluence_id :: integer(), keyword()) ::
              {:ok, [attachment()]} | {:error, term()}

  @doc "Streams the bytes of one attachment."
  @callback attachment_data(attachment(), keyword()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Pages changed since `since`, for incremental pulls.

  Sources without incremental support can implement this by returning
  `{:error, :not_supported}`; the scheduler then falls back to a snapshot.
  """
  @callback changed_since(DateTime.t(), keyword()) :: {:ok, [page()]} | {:error, term()}

  @doc """
  How much of each content type a space holds, as the site itself counts it.

  Two numbers for two requests — one per type, because Confluence Cloud does not
  filter on a comma-separated type list. `ConfluencePhxMirror.Sync.Reconcile`
  compares them with the mirror's own counts and, when they agree, lists nothing
  at all: on a healthy mirror this is the entire cost of a verify pass.

  `:page` and `:blogpost` are the types the mirror keeps; a source that cannot
  count leaves the callback out and the pass lists the space instead.
  """
  @callback counts(space_key :: String.t(), keyword()) ::
              {:ok, %{page: non_neg_integer(), blogpost: non_neg_integer()}}
              | {:error, term()}

  @doc """
  Every content id a space holds, per content type, and nothing else.

  The cheap half of `pages/2`: same pagination, no bodies, no comments, no
  attachments, no version expansion. It exists so that "name everything you
  have" costs requests whose answers are tiny — which is what a verify pass
  needs, and what a sync never does because it has to read the content anyway.

  A source without it leaves the callback out; nothing but the verify pass uses
  it.
  """
  @callback page_ids(space_key :: String.t(), keyword()) ::
              {:ok, %{page: [integer()], blogpost: [integer()]}} | {:error, term()}

  @typedoc """
  What moved in a window besides the pages themselves.

  `pages` are the pages whose comments or attachments changed — their own
  version did not, so `changed_since/2` cannot see them. `space_attachments`
  counts files a space owns for its own layout: Confluence has them, the mirror
  has nowhere to put them, and saying so is better than dropping them quietly.
  """
  @type touched :: %{pages: [integer()], space_attachments: non_neg_integer()}

  @doc """
  Pages whose comments or attachments changed since `since`.

  Every piece of content in Confluence has a version, and a child's version
  does not bump its page's, so this is what keeps an incremental run from
  missing a comment forever. Sources that cannot answer leave the callback
  out; the run then reports that details were not re-checked rather than
  pretending they were.

  `nil` asks the same question without a window — which pages have children at
  all — and is how an upgraded mirror finds what it never knew to look for.
  """
  @callback touched_since(DateTime.t() | nil, keyword()) ::
              {:ok, touched()} | {:error, term()}

  @doc """
  Read restrictions of one page.

  Return `{:ok, []}` when the page is unrestricted, which is the common case.
  Sources that cannot read restrictions leave the callback out.
  """
  @callback restrictions(confluence_id :: integer(), keyword()) ::
              {:ok, [restriction()]} | {:error, term()}

  @doc """
  Read permissions of one space.

  Confluence grants space access to principals — a person, a group, or
  anonymous readers — per operation, and the mirror only cares about `read`.
  Cloud answers these on the space itself (`/space/{key}?expand=permissions`);
  `/space/{key}/permissions` is a 404 there. A source that cannot read them
  answers `{:error, :not_supported}`, and the mirror then treats the space as
  open rather than guessing.
  """
  @callback space_permissions(space_key :: String.t(), keyword()) ::
              {:ok, [permission()]} | {:error, term()}

  @doc """
  Members of one Confluence group.

  Groups are how Confluence grants access, so the sync mirrors membership for
  every group the content refers to plus the configured admin groups. A source
  that cannot read groups leaves the callback out; the mirror then keeps the
  membership it already has.

  Confluence Cloud no longer serves this route (`/group/{name}/member` answers
  404 for a site that has the group), so a Cloud source implements
  `c:groups_of_account/2` instead.

  Each member carries whichever identifiers the site exposes:

      %{email: "jane@acme.com", account_id: "557058:...", display_name: "Jane"}
  """
  @callback group_members(group_name :: String.t(), keyword()) ::
              {:ok, [group_member()]} | {:error, term()}

  @doc """
  The groups one account belongs to, as the site names them.

  The other direction of `c:group_members/2`, and the one Confluence Cloud still
  answers: membership is learned one person at a time, for every identity the
  mirror knows — the authors its content names. A source that can list group
  members does not need this; a source that can do neither leaves both out.
  """
  @callback groups_of_account(account_id :: String.t(), keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Bytes of one space icon, with the media type the site answered with.

  Confluence's icon paths carry no file extension, so the mirror cannot infer
  the type from the path. Sources without icons leave the callback out.
  """
  @callback space_icon(icon :: %{path: String.t()}, keyword()) ::
              {:ok, %{body: binary(), media_type: String.t()}} | {:error, term()}

  @doc """
  The state of one Atlassian account, as the site reports it.

  `account_status` is whatever the site says — `"active"`, `"inactive"`,
  `"closed"` — and the sync treats everything but `"active"` as "the site has
  switched this person off". The e-mail comes back when the site is willing to
  share it, which is how a mirror account (known by address) is tied to the
  Atlassian account it belongs to.

  A source that cannot read accounts leaves the callback out, and the mirror
  keeps whatever it learned last time.
  """
  @callback user_status(account_id :: String.t(), keyword()) ::
              {:ok, account_status()} | {:error, term()}

  @optional_callbacks changed_since: 2,
                      touched_since: 2,
                      counts: 2,
                      page_ids: 2,
                      restrictions: 2,
                      space_permissions: 2,
                      space_icon: 2,
                      group_members: 2,
                      groups_of_account: 2,
                      user_status: 2,
                      web_url: 0

  @doc "The configured source module."
  def source do
    Application.get_env(
      :confluence_phx_mirror,
      :source,
      ConfluencePhxMirror.Confluence.DemoSource
    )
  end

  @doc "Whether the configured source is the bundled demo snapshot."
  @spec demo?() :: boolean()
  def demo?, do: demo?(source())

  @doc "Whether a source module is the bundled demo snapshot."
  @spec demo?(module() | nil) :: boolean()
  def demo?(module), do: kind(module) == :demo

  @doc "The kind (`:demo` or `:live`) of a source module."
  @spec kind(module() | nil) :: :demo | :live
  def kind(module) when is_atom(module) and not is_nil(module), do: module.kind()
  def kind(_module), do: :live
end
