defmodule ConfluencePhxMirrorWeb.Router do
  use ConfluencePhxMirrorWeb, :router

  alias ConfluencePhxMirrorWeb.LiveUserAuth
  alias ConfluencePhxMirrorWeb.Plugs

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConfluencePhxMirrorWeb.Layouts, :root}
    plug :protect_from_forgery
    # Scripts may only come from the mirror itself (LiveView is bundled into
    # assets/js/app.js); styles stay inline-friendly because Confluence's HTML
    # carries style attributes and the palette is emitted per request.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    }

    plug Plugs.FetchCurrentUser
    plug Plugs.ProxyAuth
    plug Plugs.AutoAdmin
    plug Plugs.Theme
    plug Plugs.SiteContext
    plug Plugs.ReaderRateLimit, scope: :html
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug Plugs.ApiAuth
    plug Plugs.ReaderRateLimit, scope: :api
  end

  # The attachment route only ever reads, so there is no state to protect with a
  # CSRF token; it fetches the session solely so the reader's permissions can be
  # applied to the bytes.
  # sobelow_skip ["Config.CSRF"]
  pipeline :attachments do
    # Attachment bytes are content: the page decides who may read them, so this
    # pipeline needs the reader's identity as much as the HTML pipeline does.
    plug :fetch_session
    plug Plugs.FetchCurrentUser
    plug Plugs.ReaderRateLimit, scope: :attachments
  end

  pipeline :webhook do
    plug :accepts, ["json"]
    plug Plugs.WebhookRateLimit
    plug Plugs.WebhookAuth, receiver: "confluence"
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  # ---------------------------------------------------------------------------
  # Reader-facing mirror
  # ---------------------------------------------------------------------------

  scope "/", ConfluencePhxMirrorWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/spaces/:key", PageController, :space
    get "/spaces/:key/overview", SpaceController, :overview
    get "/spaces/:key/blog/:id/:slug", PageController, :blog_post
    get "/spaces/:space_key/pages/:id", PageController, :show
    get "/spaces/:space_key/pages/:id/export.md", ExportController, :page
    get "/spaces/:space_key/pages/:id/:slug", PageController, :show
    get "/spaces/:key/export.zip", ExportController, :space
    get "/people/:account_id", PeopleController, :show
    get "/recent", PageController, :recent
    get "/labels/:name", PageController, :label
    get "/about", PageController, :about
    get "/theme/:name", ThemeController, :set

    get "/session", SessionController, :new
    post "/session", SessionController, :create
    get "/session/:token", SessionController, :confirm
    delete "/session", SessionController, :delete

    post "/subscriptions", SubscriptionController, :create
    delete "/subscriptions", SubscriptionController, :delete
  end

  live_session :reader, on_mount: [{LiveUserAuth, :default}] do
    scope "/", ConfluencePhxMirrorWeb do
      pipe_through :browser

      # Catalogs share one LiveView: one debounced filter box, one URL shape
      # (`?q=…&offset=…`), one "load more". Filtering and paging happen in the
      # database, so the pages stay usable with thousands of entries.
      live "/spaces", CatalogLive, :spaces
      live "/spaces/:key/pages", CatalogLive, :pages
      live "/spaces/:key/blog", CatalogLive, :blog
      live "/spaces/:key/attachments", CatalogLive, :attachments
      live "/people", CatalogLive, :people
      live "/labels", CatalogLive, :labels

      live "/search", SearchLive, :index
    end
  end

  live_session :admin, on_mount: [{LiveUserAuth, :admin}] do
    scope "/admin", ConfluencePhxMirrorWeb.Admin do
      pipe_through :browser

      live "/", DashboardLive, :index
      live "/webhooks", WebhooksLive, :index
      live "/users", UsersLive, :index
      live "/audit", AuditLive, :index
      live "/sync-log", SyncLogLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  # ---------------------------------------------------------------------------
  # Attachments (blob store)
  # ---------------------------------------------------------------------------

  scope "/attachments", ConfluencePhxMirrorWeb do
    pipe_through :attachments

    get "/:space_key/:page_id/:attachment_id/:filename", AttachmentController, :show
  end

  # ---------------------------------------------------------------------------
  # Read-only API, Confluence-inspired
  # ---------------------------------------------------------------------------

  scope "/api/v1", ConfluencePhxMirrorWeb.Api.V1 do
    pipe_through :api

    get "/spaces", SpaceController, :index
    get "/spaces/:key", SpaceController, :show
    get "/spaces/:key/pages", PageController, :index

    get "/pages/:id", PageController, :show
    get "/pages/:id/children", PageController, :children
    get "/pages/:id/ancestors", PageController, :ancestors
    get "/pages/:id/labels", PageController, :labels
    get "/pages/:id/attachments", PageController, :attachments
    get "/pages/:id/comments", PageController, :comments
    get "/pages/:id/backlinks", PageController, :backlinks
    get "/page-by-path", PageController, :by_path

    get "/labels", LabelController, :index
    get "/search", SearchController, :index
    get "/stats", StatsController, :show
  end

  # Confluence-compatible subset: existing bots keep working against the mirror.
  # The CQL search endpoints come first so `/content/search` is not captured by
  # `/content/:id`; everything else is served by the same presenters as v1.
  scope "/wiki/rest/api", ConfluencePhxMirrorWeb.Api.Confluence do
    pipe_through :api

    get "/content/search", SearchController, :index
    get "/search", SearchController, :index
  end

  scope "/wiki/rest/api", ConfluencePhxMirrorWeb.Api.V1 do
    pipe_through :api

    get "/space", SpaceController, :index
    get "/space/:key", SpaceController, :show
    get "/content", PageController, :index
    get "/content/:id", PageController, :show
    get "/content/:id/child/page", PageController, :children
    get "/content/:id/child/attachment", PageController, :attachments
    get "/content/:id/child/comment", PageController, :comments
    get "/content/:id/label", PageController, :labels
  end

  # ---------------------------------------------------------------------------
  # Webhooks and health
  # ---------------------------------------------------------------------------

  scope "/webhooks", ConfluencePhxMirrorWeb do
    pipe_through :webhook

    post "/confluence", WebhookController, :create
  end

  scope "/health", ConfluencePhxMirrorWeb do
    pipe_through :health

    get "/", HealthController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:confluence_phx_mirror, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ConfluencePhxMirrorWeb.Telemetry
    end
  end
end
