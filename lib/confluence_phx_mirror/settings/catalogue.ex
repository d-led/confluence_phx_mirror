defmodule ConfluencePhxMirror.Settings.Catalogue do
  @moduledoc """
  What an administrator may decide, declared once.

  Every entry answers four questions: the key it is stored under, how a stored
  string becomes a value again (`:type`), where the deployment's own default
  comes from (`:default`, resolved by `ConfluencePhxMirror.Settings`), and how
  the settings screen presents it (`:group`, `:label`, `:help`, `:env`).

  This module is data. `ConfluencePhxMirror.Settings` is the behaviour:
  validation, the `:persistent_term` cache and the audited transaction.

  The list is deliberately narrow. A setting belongs here only when the code
  that cares about it reads it while serving a request or running a job. A value
  read once at boot — the source, the credentials, the database, the proxy's
  identity headers — would be a lie as a stored override, so it stays
  environment-only and is reported read-only by `...Web.Admin.Config`.

  Adding a setting is therefore one entry and **no migration**: `settings` is a
  key/value table, so a key it has never seen is simply absent, and one it no
  longer knows is ignored by `Settings.load/0`.
  """

  @type type :: :string | :boolean | :pos_integer | :non_negative | :hour | :csv

  @type spec :: %{
          type: type(),
          default: term(),
          group: atom(),
          label: String.t(),
          help: String.t(),
          env: String.t() | nil,
          # Which screen presents it: the settings list, the webhook screen, the
          # theme cards — or the overview, for the one switch that is an action
          # rather than a preference.
          ui: :settings | :webhooks | :theme | :dashboard
        }

  # `:default` names *where* the deployment's value comes from, in the same
  # terms the environment writes it, so a setting and its variable cannot drift:
  #
  #   :theme                          Application.get_env(:theme)
  #   {:reader_limit, scope, floor}   :reader_rate_limit[scope][:limit]
  #   {:search, key, floor}           :search[key]
  #   {:sync, key, floor}             :sync[key]
  #   {:source, key, floor}           the configured source's own options
  #   {:notification, key, floor}     :notifications[key]
  #   {:webhook, key} / {:webhook, key, floor}   :webhooks[key] / :webhook_rate_limit
  #   {:accounts, key, floor}         :accounts[key]
  #   {:admin_stats_refresh_seconds, floor}      :admin_stats_refresh_seconds
  #   :export_personal_spaces         :export_personal_spaces
  @specs %{
    "theme" => %{
      type: :string,
      default: :theme,
      group: :appearance,
      label: "Site theme",
      help: "The palette every reader wears. Readers still choose light, dark or system.",
      env: "CM_THEME",
      ui: :theme
    },
    "reader.html_limit" => %{
      type: :pos_integer,
      default: {:reader_limit, :html, 240},
      group: :reading,
      label: "HTML requests per minute",
      help: "Reader pages, search and catalogs.",
      env: "CM_READER_RATE_LIMIT_PER_MINUTE",
      ui: :settings
    },
    "reader.api_limit" => %{
      type: :pos_integer,
      default: {:reader_limit, :api, 120},
      group: :reading,
      label: "API requests per minute",
      help: "The JSON API, per identified caller.",
      env: "CM_RATE_LIMIT_API_PER_MINUTE",
      ui: :settings
    },
    "reader.attachments_limit" => %{
      type: :pos_integer,
      default: {:reader_limit, :attachments, 300},
      group: :reading,
      label: "Attachment downloads per minute",
      help: "Images and files a reader may fetch.",
      env: "CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE",
      ui: :settings
    },
    "search.page_size" => %{
      type: :pos_integer,
      default: {:search, :page_size, 30},
      group: :reading,
      label: "Search results per page",
      help: "How many hits one reader page shows.",
      env: "CM_SEARCH_PAGE_SIZE",
      ui: :settings
    },
    "search.default_limit" => %{
      type: :pos_integer,
      default: {:search, :default_limit, 25},
      group: :reading,
      label: "Results when a caller names no limit",
      help: "API and MCP callers that ask for nothing get this many.",
      env: "CM_SEARCH_DEFAULT_LIMIT",
      ui: :settings
    },
    "search.max_results" => %{
      type: :pos_integer,
      default: {:search, :max_limit, 100},
      group: :reading,
      label: "Most results one search may return",
      help: "A ceiling, whatever a caller asks for.",
      env: "CM_SEARCH_MAX_RESULTS",
      ui: :settings
    },
    "sync.spaces" => %{
      type: :csv,
      default: :no_additions,
      group: :sync,
      label: "Spaces added at runtime",
      help:
        "Keys to add to CM_SPACES. Named where CM_SPACES names none, they are the whole whitelist — and the next run trashes the rest.",
      env: "CM_SPACES",
      ui: :settings
    },
    "sync.interval_seconds" => %{
      type: :pos_integer,
      default: {:source, :sync_interval_seconds, 3600},
      group: :sync,
      label: "How often the mirror pulls (seconds)",
      help:
        "The gap between runs, and never shorter than a run's lookback window — a page cannot slip between two of them. A new cadence applies after the tick in flight.",
      env: "CM_SYNC_INTERVAL_SECONDS",
      ui: :settings
    },
    "sync.reconcile_interval_seconds" => %{
      type: :non_negative,
      default: {:source, :reconcile_interval_seconds, 0},
      group: :sync,
      label: "How often to look for missing pages (seconds)",
      help:
        "The pass that asks every space what it holds, which is the only way a page Confluence stopped listing is noticed. 0 leaves it on the button alone.",
      env: "CM_RECONCILE_INTERVAL_SECONDS",
      ui: :settings
    },
    "confluence.page_size" => %{
      type: :pos_integer,
      default: {:source, :page_size, 50},
      group: :sync,
      label: "Pages per Confluence call",
      help:
        "A bigger page is fewer calls for the same listing, and a longer wait for the first of them.",
      env: "CM_HTTP_PAGE_SIZE",
      ui: :settings
    },
    "sync.paused" => %{
      type: :boolean,
      default: {:sync, :paused, false},
      group: :sync,
      label: "Pause Confluence calls",
      help:
        "Nothing is read from the site while this is on: runs are refused, queued jobs wait, and the screens say the mirror is paused. Reader pages keep serving what is already mirrored.",
      env: "CM_SYNC_PAUSED",
      # The overview's button beside "Sync now": stopping the site calls is the
      # first half of working on the mirror, not a preference to go and find.
      ui: :dashboard
    },
    "sync.concurrency" => %{
      type: :pos_integer,
      default: {:source, :sync_concurrency, 4},
      group: :sync,
      label: "Pages written at once",
      help: "Each holds a database connection; a shared-CPU database is happier at 2.",
      env: "CM_SYNC_CONCURRENCY",
      ui: :settings
    },
    "sync.detail_backlog" => %{
      type: :pos_integer,
      default: {:sync, :detail_backlog, 200},
      group: :sync,
      label: "Changed pages detailed per run",
      help: "Attachments and comments fetched for pages that moved, newest first.",
      env: "CM_SYNC_DETAIL_BACKLOG",
      ui: :settings
    },
    "sync.lookback_seconds" => %{
      type: :pos_integer,
      default: {:sync, :lookback_seconds, 3600},
      group: :sync,
      label: "How far back a run looks (seconds)",
      help: "A page changed more recently than this is picked up by the next run.",
      env: "CM_SYNC_LOOKBACK_SECONDS",
      ui: :settings
    },
    "notifications.enabled" => %{
      type: :boolean,
      default: {:notification, :enabled, true},
      group: :notifications,
      label: "Send e-mail",
      help: "Whether the mirror mails watchers at all.",
      env: "MIRROR_NOTIFICATIONS",
      ui: :settings
    },
    "notifications.digest_hour_utc" => %{
      type: :hour,
      default: {:notification, :digest_hour_utc, 8},
      group: :notifications,
      label: "Digest hour (UTC)",
      help: "When the daily digest goes out.",
      env: "MIRROR_DIGEST_HOUR_UTC",
      ui: :settings
    },
    "webhook.enabled" => %{
      type: :boolean,
      default: {:webhook, :enabled, true},
      group: :webhooks,
      label: "Accept deliveries",
      help: "Off answers every delivery with the endpoint's own 404.",
      env: "CM_WEBHOOK_ENABLED",
      ui: :webhooks
    },
    "webhook.require_signature" => %{
      type: :boolean,
      default: {:webhook, :require_signature},
      group: :webhooks,
      label: "Require a signature",
      help: "Deliveries must carry an HMAC of the body.",
      env: "CM_WEBHOOK_REQUIRE_SIGNATURE",
      ui: :webhooks
    },
    "webhook.rate_limit" => %{
      type: :pos_integer,
      default: {:webhook, :limit},
      group: :webhooks,
      label: "Deliveries per minute",
      help: "Per client address. A delivery is stored before it is verified.",
      env: "CM_WEBHOOK_RATE_LIMIT_PER_MINUTE",
      ui: :webhooks
    },
    "accounts.login_token_minutes" => %{
      type: :pos_integer,
      default: {:accounts, :login_token_minutes, 15},
      group: :operations,
      label: "Sign-in link lifetime (minutes)",
      help: "How long a magic link stays usable.",
      env: "CM_LOGIN_TOKEN_MINUTES",
      ui: :settings
    },
    "export.personal_spaces" => %{
      type: :boolean,
      default: :export_personal_spaces,
      group: :operations,
      label: "Include personal spaces in a site export",
      help: "A site archive is handed around; somebody's own corner usually is not.",
      env: "CM_EXPORT_PERSONAL_SPACES",
      ui: :settings
    },
    "dashboard.refresh_seconds" => %{
      type: :pos_integer,
      default: {:admin_stats_refresh_seconds, 30},
      group: :operations,
      label: "Admin overview refresh (seconds)",
      help: "How often the overview re-reads its numbers.",
      env: "CM_ADMIN_STATS_REFRESH_SECONDS",
      ui: :settings
    }
  }

  # Display order matters: it is the order an operator usually needs things in.
  @group_order [:appearance, :reading, :sync, :notifications, :operations, :webhooks]

  @groups %{
    appearance: %{
      title: "Theme",
      help: "One palette for the whole site. Readers pick light, dark or system themselves."
    },
    reading: %{
      title: "Reading",
      help: "What a reader may fetch, and how much of it one page shows."
    },
    sync: %{
      title: "Sync",
      help:
        "How often a run happens, and how hard it leans on Confluence and on the database. Pausing the calls themselves is the button beside Sync now on the overview."
    },
    notifications: %{
      title: "Notifications",
      help: "Watchers' e-mail: whether it goes out, and when."
    },
    operations: %{
      title: "Operations",
      help: "Sign-in links, exports and the overview's own cadence."
    },
    webhooks: %{
      title: "Webhooks",
      help: "The delivery intake. Edited on the Webhooks screen, where the cost is spelled out."
    }
  }

  @doc "Every spec, keyed by setting name."
  @spec all() :: %{String.t() => spec()}
  def all, do: @specs

  # Display order, which is also the order `keys/0` reports. Adding an entry to
  # `@specs` and forgetting it here fails `Settings.CatalogueTest`.
  @order [
    "theme",
    "reader.html_limit",
    "reader.api_limit",
    "reader.attachments_limit",
    "search.page_size",
    "search.default_limit",
    "search.max_results",
    "sync.interval_seconds",
    "sync.reconcile_interval_seconds",
    "sync.paused",
    "sync.spaces",
    "sync.concurrency",
    "sync.detail_backlog",
    "sync.lookback_seconds",
    "confluence.page_size",
    "notifications.enabled",
    "notifications.digest_hour_utc",
    "webhook.enabled",
    "webhook.require_signature",
    "webhook.rate_limit",
    "accounts.login_token_minutes",
    "export.personal_spaces",
    "dashboard.refresh_seconds"
  ]

  @doc "Every key, in display order."
  @spec keys() :: [String.t()]
  def keys, do: @order

  @doc "Whether `key` is a setting this mirror knows."
  @spec known?(String.t()) :: boolean()
  def known?(key), do: Map.has_key?(@specs, key)

  @doc "The spec for `key`, or an argument error naming it."
  @spec fetch!(String.t()) :: spec()
  def fetch!(key) do
    case Map.fetch(@specs, key) do
      {:ok, spec} -> Map.put_new(spec, :ui, :settings)
      :error -> raise ArgumentError, "#{inspect(key)} is not a setting this mirror knows"
    end
  end

  @doc """
  The groups one interface (`:settings`, `:webhooks`, `:theme`) presents, in
  display order, each with the keys it shows.
  """
  @spec groups(:settings | :webhooks | :theme) :: [map()]
  def groups(ui) do
    @group_order
    |> Enum.map(&{&1, Enum.filter(keys_in(&1), fn key -> fetch!(key).ui == ui end)})
    |> Enum.reject(fn {_group, keys} -> keys == [] end)
    |> Enum.map(fn {group, keys} ->
      @groups |> Map.fetch!(group) |> Map.put(:key, group) |> Map.put(:keys, keys)
    end)
  end

  @doc "The keys of one group, in display order."
  @spec keys_in(atom()) :: [String.t()]
  def keys_in(group), do: Enum.filter(@order, &(fetch!(&1).group == group))
end
