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

  @type type ::
          :string
          | :boolean
          | :pos_integer
          | :non_negative
          | :hour
          | :csv
          # One of a list, with the label the screen shows beside each value:
          # the set a value must belong to is the catalogue's, not the type's.
          | {:choice, [{String.t(), String.t()}]}

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
  #   :landing_page                   Application.get_env(:landing_page)
  #   {:reader_limit, scope, floor}   :reader_rate_limit[scope][:limit]
  #   {:search, key, floor}           :search[key]
  #   {:sync, key, floor}             :sync[key]
  #   {:source, key, floor}           the configured source's own options
  #   {:notification, key, floor}     :notifications[key]
  #   {:mail, key, floor}             the mailer's own configuration
  #   {:mail_from, part}              :mail_from, as its name or its address
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
    "site.landing_page" => %{
      type:
        {:choice,
         [
           {"home", "The mirror's home: what changed, its spaces, its labels"},
           {"spaces", "The space directory"}
         ]},
      default: :landing_page,
      group: :site,
      label: "Landing page",
      help:
        "What a reader sees at /. Confluence's own site landing page is not readable over REST, so this is the mirror's choice.",
      env: "CM_LANDING_PAGE",
      ui: :settings
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
    "sync.live_doc_refresh_seconds" => %{
      type: :pos_integer,
      default: {:sync, :live_doc_refresh_seconds, 900},
      group: :sync,
      label: "Live docs read at most every (seconds)",
      help:
        "A live doc is edited continuously by design, so its version moves constantly. Reading it once per this many seconds keeps its copy honest without chasing keystrokes; a resync on the page means now.",
      env: "CM_LIVE_DOC_REFRESH_SECONDS",
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
    "notifications.window_seconds" => %{
      type: :pos_integer,
      default: {:notification, :window_seconds, 120},
      group: :notifications,
      label: "Collect changes for (seconds)",
      help:
        "How long a burst of changes is collected before one message goes out. A sync that changes a hundred pages mails a reader once, not a hundred times. One second sends each change almost as it comes.",
      env: "MIRROR_NOTIFICATION_WINDOW_SECONDS",
      ui: :settings
    },
    "mail.relay" => %{
      type: :string,
      default: {:mail, :relay, nil},
      group: :mail,
      label: "SMTP relay",
      help:
        "Hostname of the server that sends the mirror's mail. Empty and the deployment's adapter is used — with no relay at all, mail is written to a file and never sent.",
      env: "SMTP_RELAY",
      ui: :settings
    },
    "mail.port" => %{
      type: :pos_integer,
      default: {:mail, :port, 587},
      group: :mail,
      label: "Port",
      help: "587 for a submission relay; 465 usually wants TLS always.",
      env: "SMTP_PORT",
      ui: :settings
    },
    "mail.username" => %{
      type: :string,
      default: {:mail, :username, nil},
      group: :mail,
      label: "Username",
      help:
        "Empty means the relay needs no credentials. Many relay accounts ask for a login here and a separate key as the password — neither is the sender below.",
      env: "SMTP_USERNAME",
      ui: :settings
    },
    "mail.tls" => %{
      type: {:choice, [{"always", "Always"}, {"never", "Never"}]},
      default: {:mail, :tls, "always"},
      group: :mail,
      label: "TLS",
      help: "`Never` is for a relay on the same host; a submission port wants `Always`.",
      env: "SMTP_TLS",
      ui: :settings
    },
    "mail.auth" => %{
      type: {:choice, [{"always", "Always"}, {"never", "Never"}]},
      default: {:mail, :auth, "always"},
      group: :mail,
      label: "Authentication",
      help: "`Never` for a relay that takes no credentials.",
      env: "SMTP_AUTH",
      ui: :settings
    },
    # Who the mail is from, as opposed to whom it is sent as: a relay rejects a
    # sender it does not host or has not verified, and that address is rarely the
    # account that authenticates.
    "mail.from" => %{
      type: :string,
      default: {:mail_from, :address},
      group: :mail,
      label: "Sender address",
      help:
        "What every message is from. A hosted relay accepts only an address it owns or has verified, and refuses the rest.",
      env: "MIRROR_MAIL_FROM",
      ui: :settings
    },
    "mail.from_name" => %{
      type: :string,
      default: {:mail_from, :name},
      group: :mail,
      label: "Sender name",
      help: "The name a reader sees beside the sender address.",
      env: "MIRROR_MAIL_FROM_NAME",
      ui: :settings
    },
    # The queue's own switch, beside the server it drains through: a relay that
    # is wrong is worth stopping, and so is one that sends to the wrong people.
    "mail.paused" => %{
      type: :boolean,
      default: :mail_paused,
      group: :mail,
      label: "Pause mail",
      help:
        "Nothing leaves the mirror while this is on: notifications and digests wait in the queue and go out after the resume, and a reader's test message is refused. Sign-in links are not queued and keep working — a pause must never lock anybody out.",
      env: "MIRROR_MAIL_PAUSED",
      ui: :settings
    },
    # What the provider sells, in messages a day. The mirror counts before it
    # sends, because the alternative is learning the limit by being refused —
    # and a refused digest is a digest the reader never gets.
    "mail.per_day" => %{
      type: :pos_integer,
      default: {:mail_daily, :limit, 300},
      group: :mail,
      label: "Messages a day",
      help:
        "What the relay allows in one day — the number its plan names. A day's queue stops when this is reached and carries on after midnight UTC.",
      env: "CM_MAIL_PER_DAY",
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
    "export.prepared" => %{
      type: :boolean,
      default: :export_prepared,
      group: :operations,
      label: "Prepare a site export before it is downloaded",
      help:
        "Writes the archive to the deployment's temporary folder and serves that file: it says how big it is and a broken download can be resumed. Off, the archive is generated while it is sent — smaller and immediate, but a download that stops has to start again.",
      env: "CM_EXPORT_PREPARED",
      ui: :settings
    },
    "trash.retention_days" => %{
      type: :non_negative,
      default: {:trash, :retention_days, 30},
      group: :operations,
      label: "Days a deleted space or page is kept",
      help:
        "A page the site stopped listing, or one an administrator deleted, waits this long in the trash \u2014 its rows and its attachment files \u2014 before a nightly purge removes both. `0` keeps the trash until somebody empties it by hand.",
      env: "CM_TRASH_RETENTION_DAYS",
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
  @group_order [
    :appearance,
    :site,
    :reading,
    :sync,
    :notifications,
    :mail,
    :operations,
    :webhooks
  ]

  @groups %{
    appearance: %{
      title: "Theme",
      help: "One palette for the whole site. Readers pick light, dark or system themselves."
    },
    site: %{
      title: "Site",
      help: "What this mirror says it is, and where a reader lands when they arrive."
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
    mail: %{
      title: "Mail server",
      help:
        "How the mirror sends mail, and who it is from. The deployment's `SMTP_*` and `MIRROR_MAIL_FROM*` variables are the defaults; a value stored here wins and takes effect without a restart — and every reader can send themselves a test e-mail to see it arrive. The password is the exception: set `SMTP_PASSWORD` for the deployment, because a secret in this database would travel in every backup of it."
    },
    operations: %{
      title: "Operations",
      help: "Sign-in links, the trash, exports and the overview's own cadence."
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
    "site.landing_page",
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
    "sync.live_doc_refresh_seconds",
    "confluence.page_size",
    "notifications.enabled",
    "notifications.digest_hour_utc",
    "notifications.window_seconds",
    "mail.relay",
    "mail.port",
    "mail.username",
    "mail.tls",
    "mail.auth",
    "mail.from",
    "mail.from_name",
    "mail.paused",
    "mail.per_day",
    "webhook.enabled",
    "webhook.require_signature",
    "webhook.rate_limit",
    "accounts.login_token_minutes",
    "export.personal_spaces",
    "export.prepared",
    "trash.retention_days",
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
