defmodule ConfluencePhxMirror.Confluence.DemoContent do
  @moduledoc """
  Sample Confluence content that exercises the whole mirror: nested page trees,
  cross-space links, labels, comments, attachments, archived pages, blog posts
  and the common macros as Confluence renders them in `export_view`
  (panels, code, expand, status, TOC, children, gallery, Jira issue, tasks…).

  It is written the way the REST API returns content, so the demo source and
  the HTTP source feed the same sync pipeline.
  """

  import Plug.HTML, only: [html_escape: 1]

  @base_url "https://demo.atlassian.net"

  # A realistic hierarchy needs breadth and depth: twenty services under one
  # operations page, and a six-level chain below it, so the tree, the space
  # catalogue and the breadcrumb trail all have to cope with real shape.
  @operations_id 1010
  @first_service_id 1100
  @first_deep_id 1200

  @service_topics [
    "API Gateway",
    "Authentication",
    "Service Mesh",
    "Message Queue",
    "Schema Registry",
    "Observability",
    "Incident Response",
    "Capacity Planning",
    "Cost Controls",
    "Data Model",
    "Release Engineering",
    "Mobile Clients",
    "Partner Integrations",
    "Billing",
    "Search Ranking",
    "Notifications",
    "Batch Processing",
    "Disaster Recovery",
    "Secrets Management",
    "Developer Portal"
  ]

  @deep_titles [
    "Platform Operations",
    "Networking",
    "Edge",
    "TLS",
    "Certificate Rotation",
    "Emergency Revocation"
  ]

  @extra_index (
                 services =
                   @service_topics
                   |> Enum.with_index()
                   |> Map.new(fn {topic, index} ->
                     {@first_service_id + index,
                      {"ENG", "Engineering Handbook", "Service: #{topic}"}}
                   end)

                 deep =
                   @deep_titles
                   |> Enum.with_index()
                   |> Map.new(fn {title, index} ->
                     {@first_deep_id + index, {"ENG", "Engineering Handbook", title}}
                   end)

                 services
                 |> Map.merge(deep)
                 |> Map.put(@operations_id, {"ENG", "Engineering Handbook", "Operations"})
               )

  @base_index %{
    1000 => {"ENG", "Engineering Handbook", "Home"},
    1001 => {"ENG", "Engineering Handbook", "Getting Started"},
    1002 => {"ENG", "Engineering Handbook", "Architecture Overview"},
    1003 => {"ENG", "Engineering Handbook", "Macros Gallery"},
    1004 => {"ENG", "Engineering Handbook", "Search and CQL"},
    1005 => {"ENG", "Engineering Handbook", "Attachments and Images"},
    1006 => {"ENG", "Engineering Handbook", "Cross-links and Backlinks"},
    1007 => {"ENG", "Engineering Handbook", "Meeting Notes"},
    1008 => {"ENG", "Engineering Handbook", "API Guide"},
    1009 => {"ENG", "Engineering Handbook", "Deprecated Setup"},
    2000 => {"PROD", "Product Hub", "Product Hub"},
    2001 => {"PROD", "Product Hub", "Release 2.0"},
    2002 => {"PROD", "Product Hub", "Roadmap"}
  }

  @page_index Map.merge(@base_index, @extra_index)

  @doc "Space DTOs exactly as the sync expects them."
  def spaces do
    [
      %{
        key: "ENG",
        name: "Engineering Handbook",
        type: "global",
        description: "How we build, test and run the platform.",
        homepage_id: 1000,
        labels: ["platform"],
        url: "#{@base_url}/wiki/spaces/ENG"
      },
      %{
        key: "PROD",
        name: "Product Hub",
        type: "global",
        description: "Product plans, releases and roadmap.",
        homepage_id: 2000,
        labels: ["product"],
        url: "#{@base_url}/wiki/spaces/PROD"
      }
    ]
  end

  @doc "Page and blog post DTOs (without computed ancestors)."
  def pages do
    [
      page(1000, "ENG", nil, "Engineering Handbook", home_body(), ~w(home handbook),
        version: 12,
        message: "Refresh landing page",
        updated_at: ~U[2026-10-19 14:05:00Z]
      ),
      page(1001, "ENG", 1000, "Getting Started", getting_started_body(), ~w(onboarding howto),
        version: 8,
        message: "Add first-week checklist",
        updated_at: ~U[2026-10-18 09:30:00Z]
      ),
      page(
        1002,
        "ENG",
        1001,
        "Architecture Overview",
        architecture_body(),
        ~w(architecture design),
        version: 15,
        message: "Document the sync pipeline",
        updated_at: ~U[2026-10-20 08:10:00Z],
        storage:
          properties_storage(
            architecture_body(),
            [{"Owner", "Platform"}, {"Status", "Active"}]
          )
      ),
      page(1003, "ENG", 1001, "Macros Gallery", macros_body(), ~w(macros demo),
        version: 4,
        message: "Show every macro we support",
        updated_at: ~U[2026-10-17 16:45:00Z],
        storage: properties_storage(macros_body(), [{"Owner", "Docs"}, {"Status", "Review"}])
      ),
      page(1004, "ENG", 1000, "Search and CQL", search_body(), ~w(search howto),
        version: 6,
        message: "Document CQL fields",
        updated_at: ~U[2026-10-16 11:20:00Z]
      ),
      page(
        1005,
        "ENG",
        1000,
        "Attachments and Images",
        attachments_page_body(),
        ~w(attachments demo),
        version: 9,
        message: "Add sample report",
        updated_at: ~U[2026-10-15 13:00:00Z]
      ),
      page(1006, "ENG", 1000, "Cross-links and Backlinks", crosslinks_body(), ~w(links backlinks),
        version: 3,
        message: "Demonstrate internal and external links",
        updated_at: ~U[2026-10-14 10:15:00Z]
      ),
      page(1007, "ENG", 1000, "Meeting Notes", meeting_body(), ~w(meeting notes),
        version: 21,
        message: "Weekly sync notes",
        updated_at: ~U[2026-10-20 15:40:00Z],
        author: "Sam Rivera"
      ),
      page(1008, "ENG", 1000, "API Guide", api_body(), ~w(api reference),
        version: 5,
        message: "Document mirror endpoints",
        updated_at: ~U[2026-10-13 09:05:00Z],
        author: "Priya Nair"
      ),
      page(1009, "ENG", 1000, "Deprecated Setup", deprecated_body(), ~w(legacy),
        version: 2,
        status: "archived",
        message: "Archived: replaced by Getting Started",
        updated_at: ~U[2025-11-02 12:00:00Z]
      ),
      page(2000, "PROD", nil, "Product Hub", product_home_body(), ~w(product home),
        version: 7,
        message: "Link release notes",
        updated_at: ~U[2026-10-20 07:30:00Z],
        author: "Priya Nair"
      ),
      page(2001, "PROD", nil, "Release 2.0", release_body(), ~w(release announcement),
        version: 3,
        type: "blogpost",
        message: "Publish release notes",
        created_at: ~U[2026-10-01 08:00:00Z],
        updated_at: ~U[2026-10-01 08:00:00Z],
        author: "Priya Nair"
      ),
      page(2002, "PROD", 2000, "Roadmap", roadmap_body(), ~w(roadmap planning),
        version: 11,
        message: "Q4 priorities",
        updated_at: ~U[2026-10-12 17:25:00Z],
        author: "Sam Rivera"
      )
    ] ++
      [
        page(@operations_id, "ENG", 1000, "Operations", operations_body(), ~w(operations runbook),
          version: 4,
          message: "Point at the service runbooks",
          updated_at: ~U[2026-10-19 08:45:00Z]
        )
      ] ++ service_pages() ++ deep_pages()
  end

  @doc "Attachment metadata plus the demo bytes."
  def attachments do
    [
      attachment(9001, 1002, "diagram.svg", "image/svg+xml", diagram_svg()),
      attachment(9002, 1002, "architecture.csv", "text/csv", architecture_csv()),
      attachment(9003, 1005, "sample-report.pdf", "application/pdf", sample_pdf()),
      attachment(9004, 1005, "roadmap.csv", "text/csv", roadmap_csv()),
      attachment(9005, 1005, "notes.md", "text/markdown", notes_md()),
      attachment(9006, 1005, "screenshot.png", "image/png", screenshot_png()),
      attachment(9007, 1005, "diagram.svg", "image/svg+xml", diagram_svg()),
      attachment(9008, 2002, "roadmap.csv", "text/csv", roadmap_csv())
    ]
  end

  @doc "Comments and replies."
  def comments do
    [
      %{
        id: 3001,
        page_id: 1001,
        parent_id: nil,
        author: "Sam Rivera",
        body_export: "<p>Nice checklist. Could we add the VPN steps for contractors?</p>",
        created_at: ~U[2026-10-18 10:05:00Z],
        url: "#{@base_url}/wiki/spaces/ENG/pages/1001/Getting+Started?focusedCommentId=3001"
      },
      %{
        id: 3002,
        page_id: 1001,
        parent_id: 3001,
        author: "Jane Doe",
        body_export: "<p>Good point — added a <em>Contractors</em> section below.</p>",
        created_at: ~U[2026-10-18 11:20:00Z],
        url: "#{@base_url}/wiki/spaces/ENG/pages/1001/Getting+Started?focusedCommentId=3002"
      },
      %{
        id: 3003,
        page_id: 1002,
        parent_id: nil,
        author: "Priya Nair",
        body_export:
          "<p>The <strong>poll → render</strong> split is what makes partial syncs safe. 👍</p>",
        created_at: ~U[2026-10-20 09:00:00Z],
        url: "#{@base_url}/wiki/spaces/ENG/pages/1002/Architecture+Overview?focusedCommentId=3003"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Page bodies
  # ---------------------------------------------------------------------------

  defp home_body do
    doc("""
    #{panel(:info, "Welcome to the Engineering Handbook", "<p>Everything a new engineer needs: onboarding, architecture, how we search the mirror and how to reach the API.</p>" <> "<p>Start with #{page_link(1001, "Getting Started")} or jump to #{page_link(1002, "Architecture Overview")}.</p>")}
    <h2 id="handbook-map">Handbook map</h2>
    <div class="mirror-macro" data-macro="children"></div>
    <h2 id="recently-updated">Recently updated</h2>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Page</th><th class="confluenceTh">Owner</th><th class="confluenceTh">Updated</th></tr>
        <tr><td class="confluenceTd">#{page_link(1002, "Architecture Overview")}</td><td class="confluenceTd">Jane Doe</td><td class="confluenceTd">20 Oct 2026</td></tr>
        <tr><td class="confluenceTd">#{page_link(1007, "Meeting Notes")}</td><td class="confluenceTd">Sam Rivera</td><td class="confluenceTd">20 Oct 2026</td></tr>
        <tr><td class="confluenceTd">#{page_link(1004, "Search and CQL")}</td><td class="confluenceTd">Jane Doe</td><td class="confluenceTd">16 Oct 2026</td></tr>
      </tbody>
    </table>
    #{panel(:tip, "Try the search", "<p>The mirror search understands a CQL subset, for example <code>space = ENG AND label = architecture</code>. See #{page_link(1004, "Search and CQL")}.</p>")}
    """)
  end

  defp getting_started_body do
    doc("""
    <p>#{lozenge(:inprogress, "ONBOARDING")} #{lozenge(:success, "DOCUMENTED")}</p>
    <div class="mirror-macro" data-macro="toc"></div>
    <h2 id="day-one">Day one</h2>
    #{panel(:tip, "Before your first coffee", "<p>Install the toolchain, clone the workspace and run <code>mix setup</code>. The mirror should be available at <code>http://localhost:4000</code>.</p>")}
    #{code("bash", ~s|mix setup\nmix phx.server\n# then open http://localhost:4000|)}
    <h2 id="first-week">First week</h2>
    <ul class="inline-task-list">
      <li data-inline-task-id="1" class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Read the #{page_link(1002, "architecture overview")}</li>
      <li data-inline-task-id="2" class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Ship a documentation fix</li>
      <li data-inline-task-id="3" class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Join the on-call shadow rotation</li>
      <li data-inline-task-id="4"><span class="aui-icon aui-icon-small aui-iconfont-tick">☐</span> Present at Friday demo</li>
    </ul>
    #{expand("What happens on the first Friday?",
    "<p>Every new engineer shows a five minute demo of something they shipped or fixed. Slides are optional, curiosity is not. 🙂</p>")}
    <h2 id="contractors">Contractors</h2>
    #{panel(:warning, "Access needs a sponsor", "<p>Contractors get VPN access through their sponsor. Ask your sponsor to open a request; the mirror itself is read-only and available on the intranet.</p>")}
    <h2 id="where-to-ask">Where to ask</h2>
    <p>Ping #{user_link("jane.doe", "Jane Doe")} for architecture and #{user_link("sam.rivera", "Sam Rivera")} for operations.</p>
    #{panel(:note, "This page is the source of truth", "<p>These notes are mirrored from Confluence. The <em>original</em> stays authoritative — use the “View original” link at the top of the mirrored page.</p>")}
    """)
  end

  defp architecture_body do
    doc("""
    #{excerpt("<p>The mirror is a read-only cache: a poll → render → index pipeline writes Confluence content into Postgres and files into the blob store.</p>")}
    <h2 id="overview">Overview</h2>
    <p>Three stages, each independently retryable:</p>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Stage</th><th class="confluenceTh">Responsibility</th><th class="confluenceTh">Owner</th></tr>
        <tr><td class="confluenceTd"><strong>Poll</strong></td><td class="confluenceTd">Fetch pages and attachments with a rate-limited client; snapshot or incremental.</td><td class="confluenceTd">Sync</td></tr>
        <tr><td class="confluenceTd"><strong>Render</strong></td><td class="confluenceTd">Keep <code>export_view</code> markup, rewrite links, sanitise script tags, store link records.</td><td class="confluenceTd">Renderer</td></tr>
        <tr><td class="confluenceTd"><strong>Index</strong></td><td class="confluenceTd">Derive plain text and let Postgres maintain the <code>tsvector</code> for CQL search.</td><td class="confluenceTd">Postgres</td></tr>
      </tbody>
    </table>
    #{image(1002, "diagram.svg", "Sync architecture diagram")}
    <h2 id="pipeline">The pipeline</h2>
    #{code("elixir", ~s[page
|> Mirror.upsert_page(space, attrs)
|> Renderer.render(space_key: space.key, pages: page_index)
|> Mirror.store_rendered(page, result)
|> Notifications.page_updated(page)])}
    #{expand("Why store the export view as well as the storage format?",
    "<p>The storage format is the portable source and is exposed by the API. The export view is what Confluence itself renders, including macros we do not implement ourselves. Storing both lets the mirror show exactly what Confluence shows without re-implementing every macro.</p>")}
    #{panel(:info, "Decision record", "<p>Attachments are <strong>not</strong> stored in Postgres. They live under <code>spaces/&lt;KEY&gt;/pages/&lt;id&gt;/attachments/&lt;id&gt;/&lt;file&gt;</code> behind a blob-store behaviour.</p><p>Related: #{page_link(1005, "Attachments and Images")}.</p>")}
    <p>Data model details are mirrored in <a href="/wiki/download/attachments/1002/architecture.csv?version=1">architecture.csv</a>.</p>
    <p>Back to #{page_link(1001, "Getting Started")}.</p>
    """)
  end

  defp macros_body do
    doc("""
    <p>This page collects the macros the mirror renders through Confluence's own <code>export_view</code>.</p>
    <div class="toc-macro client-side-toc-macro">
      <ul class="toc-indentation">
        <li><a href="#panels">Panels</a></li>
        <li><a href="#code">Code &amp; preformatted text</a></li>
        <li><a href="#structure">Structure</a></li>
        <li><a href="#tasks">Tasks</a></li>
        <li><a href="#gallery">Gallery</a></li>
        <li><a href="#jira">Jira issue</a></li>
      </ul>
    </div>
    <h2 id="panels">Panels</h2>
    #{panel(:info, "Info panel", "<p>Use for context and orientation.</p>")}
    #{panel(:note, "Note panel", "<p>Use for asides that should not interrupt reading.</p>")}
    #{panel(:tip, "Tip panel", "<p>Use for shortcuts. Press <kbd>⌘</kbd>+<kbd>K</kbd> to search.</p>")}
    #{panel(:warning, "Warning panel", "<p>The mirror is read-only; edits belong in Confluence.</p>")}
    #{panel(:error, "Error panel", "<p>If the sync shows <strong>failed</strong>, check the audit log first.</p>")}
    <p>Statuses: #{lozenge(:success, "DONE")} #{lozenge(:inprogress, "IN PROGRESS")} #{lozenge(:moved, "MOVED")} #{lozenge(:default, "BACKLOG")}</p>
    <h2 id="code">Code &amp; preformatted text</h2>
    #{code("javascript", ~s|const response = await fetch('/api/v1/pages/1002');\nconst page = await response.json();\nconsole.log(page.title);|)}
    #{code("sql", ~s|SELECT title, ts_rank_cd(search_vector, q) AS rank\nFROM pages, websearch_to_tsquery('simple', 'mirror pipeline') q\nWHERE search_vector @@ q\nORDER BY rank DESC;|)}
    <div class="preformatted panel"><div class="preformattedContent panelContent"><pre>No formatting here.
      Indentation and *asterisks* survive verbatim.</pre></div></div>
    <blockquote><p>Quotes keep their emphasis in the export view.</p></blockquote>
    <h2 id="structure">Structure</h2>
    #{expand("Expand macro (collapsed by default)", "<p>Hidden content is still mirrored and searchable.</p><ul><li>One</li><li>Two</li></ul>")}
    <details><summary>Details macro</summary><p>Native HTML details/summary, no JavaScript required.</p></details>
    <h3>Columns macro</h3>
    <div class="contentLayout2">
      <div class="columnLayout two-equal" data-layout="two-equal">
        <div class="cell normal" data-type="normal"><p><strong>Left column</strong></p><p>Layouts are simple divs in the export view.</p></div>
        <div class="cell normal" data-type="normal"><p><strong>Right column</strong></p><p>They stay readable on narrow screens thanks to our CSS.</p></div>
      </div>
    </div>
    <span id="anchor-demo" class="confluence-anchor-link"></span>
    <h3>Children display</h3>
    #{children_macro([1002, 1003])}
    <h2 id="tasks">Tasks</h2>
    <ul class="inline-task-list">
      <li data-inline-task-id="1" class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Mirror panels</li>
      <li data-inline-task-id="2" class="checked"><span class="aui-icon aui-icon-small aui-iconfont-tick">✓</span> Mirror code blocks</li>
      <li data-inline-task-id="3"><span class="aui-icon aui-icon-small aui-iconfont-tick">☐</span> Mirror the Jira macro detail view</li>
    </ul>
    <h2 id="gallery">Gallery</h2>
    #{gallery([{1005, "screenshot.png", "Reader view"}, {1005, "diagram.svg", "Architecture"}])}
    <h2 id="jira">Jira issue</h2>
    <div class="jira-issue-macro" data-jira-key="ENG-42">
      <a class="jira-issue-key" href="#{@base_url}/browse/ENG-42">ENG-42</a>
      <span class="summary">Flaky build on CI</span>
      #{lozenge(:success, "Done")}
    </div>
    <p>Mentioning #{user_link("priya.nair", "Priya Nair")} renders as a user link.</p>
    <p>Jump to the <a href="#panels">panels</a> anchor or the <span class="confluence-anchor-link" id="anchor-demo-2">anchor demo</span>.</p>
    <h2 id="dynamic">Dynamic content the mirror resolves itself</h2>
    <p>
      Confluence renders these macros in the browser, so <code>export_view</code>
      only carries a placeholder. The mirror resolves them at sync time from its own
      database and bakes the result into the page: no JavaScript, still searchable.
    </p>
    <div class="mirror-macro" data-macro="content-by-label" data-labels="architecture" data-limit="5"></div>
    <div class="mirror-macro" data-macro="detailssummary" data-columns="Owner,Status"></div>
    """)
  end

  defp search_body do
    doc("""
    #{panel(:info, "Search is Postgres, not a search engine", "<p>Every mirrored page carries a stored <code>tsvector</code>. CQL is parsed into SQL, so results are always consistent with the database and need no reindexing service.</p>")}
    <h2 id="syntax">CQL subset</h2>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Field</th><th class="confluenceTh">Operators</th><th class="confluenceTh">Example</th></tr>
        <tr><td class="confluenceTd"><code>text</code></td><td class="confluenceTd"><code>~</code></td><td class="confluenceTd"><code>text ~ "rate limit"</code></td></tr>
        <tr><td class="confluenceTd"><code>title</code></td><td class="confluenceTd"><code>=</code>, <code>~</code></td><td class="confluenceTd"><code>title ~ "release"</code></td></tr>
        <tr><td class="confluenceTd"><code>space</code></td><td class="confluenceTd"><code>=</code>, <code>!=</code></td><td class="confluenceTd"><code>space = ENG</code></td></tr>
        <tr><td class="confluenceTd"><code>label</code></td><td class="confluenceTd"><code>=</code>, <code>!=</code></td><td class="confluenceTd"><code>label = architecture</code></td></tr>
        <tr><td class="confluenceTd"><code>type</code></td><td class="confluenceTd"><code>=</code></td><td class="confluenceTd"><code>type = blogpost</code></td></tr>
        <tr><td class="confluenceTd"><code>creator</code></td><td class="confluenceTd"><code>=</code></td><td class="confluenceTd"><code>creator = "Jane Doe"</code></td></tr>
        <tr><td class="confluenceTd"><code>ancestor</code></td><td class="confluenceTd"><code>=</code></td><td class="confluenceTd"><code>ancestor = 1000</code></td></tr>
        <tr><td class="confluenceTd"><code>created</code>, <code>lastmodified</code></td><td class="confluenceTd"><code>&gt;</code>, <code>&lt;</code></td><td class="confluenceTd"><code>lastmodified &gt; startOfMonth()</code></td></tr>
        <tr><td class="confluenceTd">any field</td><td class="confluenceTd"><code>in</code>, <code>not in</code></td><td class="confluenceTd"><code>label in (architecture, design)</code></td></tr>
      </tbody>
    </table>
    <h2 id="examples">Examples</h2>
    #{code("text", ~s|space = ENG AND label = architecture ORDER BY lastmodified DESC, title\nlabel in (architecture, design) and space not in (OLD, ARCHIVE)\ntext ~ "rate limit" AND type = page\nlastmodified > startOfDay("-7d") AND title !~ draft|)}
    <p>The same CQL works against <code>GET /api/v1/search?cql=…</code>; see the #{page_link(1008, "API Guide")}.</p>
    #{panel(:tip, "Performance", "<p>Label and ancestor filters use GIN indexes on array columns; text filters use the generated <code>tsvector</code> index. A page tree filter never walks the tree recursively.</p>")}
    """)
  end

  defp attachments_page_body do
    doc("""
    <h2 id="images">Images</h2>
    <p>Embedded images are pulled from Confluence and served from the mirror's blob store.</p>
    #{image(1005, "screenshot.png", "Reader view screenshot", ~s(width="480"))}
    #{image(1005, "diagram.svg", "Architecture diagram")}
    <h2 id="files">Files</h2>
    <ul>
      <li><a href="/wiki/download/attachments/1005/sample-report.pdf?version=2">sample-report.pdf</a> — a PDF attachment</li>
      <li><a href="/wiki/download/attachments/1005/roadmap.csv?version=1">roadmap.csv</a> — comma separated data</li>
      <li><a href="/wiki/download/attachments/1005/notes.md?version=1">notes.md</a> — markdown notes</li>
    </ul>
    <h2 id="cross-page">Cross-page attachment</h2>
    <p>This link points at an attachment of #{page_link(1002, "Architecture Overview")} and therefore stays on the source site:</p>
    <p><a href="/wiki/download/attachments/1002/diagram.svg?version=1">diagram.svg (from Architecture Overview)</a></p>
    #{panel(:note, "Blob layout", "<p>Files are stored by space, page and attachment id — no database blobs, no S3 dependency. The store is behind a behaviour, so S3 can be added later.</p>")}
    """)
  end

  defp crosslinks_body do
    doc("""
    <h2 id="internal">Internal links</h2>
    <p>#{page_link(1002, "Architecture Overview")} and #{page_link(1003, "Macros Gallery")} are mirrored, so these links stay inside the mirror.</p>
    <h2 id="cross-space">Cross-space</h2>
    <p>#{page_link(2000, "Product Home")} and the blog post #{page_link(2001, "Release 2.0")} live in another space and are still mirrored.</p>
    <h2 id="unmirrored">Unmirrored page</h2>
    <p><a href="/wiki/spaces/ENG/pages/9999/Secret+Notes">Secret Notes</a> is not mirrored; the link points back to Confluence.</p>
    <h2 id="external">External</h2>
    <p><a href="https://developer.atlassian.com/cloud/confluence/using-the-rest-api/">Confluence REST API documentation</a> and <a href="https://www.postgresql.org/docs/current/textsearch.html">Postgres full-text search</a>.</p>
    #{panel(:info, "Backlinks", "<p>Every internal link is stored in the link table, which powers the “Linked from” panel on the target page and the “Outgoing links” panel here.</p>")}
    """)
  end

  defp meeting_body do
    doc("""
    <p><strong>Date:</strong> 20 October 2026 · <strong>Facilitator:</strong> #{user_link("sam.rivera", "Sam Rivera")}</p>
    <p><strong>Attendees:</strong> #{user_link("jane.doe", "Jane Doe")}, #{user_link("priya.nair", "Priya Nair")}</p>
    <h2 id="decisions">Decisions</h2>
    <ul>
      <li>Snapshot every 15 minutes, webhooks for urgent changes. #{lozenge(:success, "AGREED")}</li>
      <li>Keep export view markup; do not re-implement macros. #{lozenge(:success, "AGREED")}</li>
      <li>Attachments on the filesystem behind the blob abstraction. #{lozenge(:inprogress, "IN PROGRESS")}</li>
    </ul>
    <h2 id="actions">Action items</h2>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Action</th><th class="confluenceTh">Owner</th><th class="confluenceTh">Status</th></tr>
        <tr><td class="confluenceTd">Add webhook signature verification</td><td class="confluenceTd">Jane</td><td class="confluenceTd">#{lozenge(:success, "DONE")}</td></tr>
        <tr><td class="confluenceTd">Measure CQL query plans</td><td class="confluenceTd">Priya</td><td class="confluenceTd">#{lozenge(:inprogress, "DOING")}</td></tr>
        <tr><td class="confluenceTd">Write the reader rate-limit doc</td><td class="confluenceTd">Sam</td><td class="confluenceTd">#{lozenge(:default, "TODO")}</td></tr>
      </tbody>
    </table>
    #{expand("Raw notes", "<ul><li>Sync worker retries are per page.</li><li>Mail goes to smtp4dev in dev.</li><li>Labels are lower-cased and de-duplicated.</li></ul>")}
    """)
  end

  defp api_body do
    doc("""
    #{panel(:warning, "Read-only", "<p>The API exposes mirrored content only. Write endpoints do not exist by design.</p>")}
    <h2 id="auth">Authentication</h2>
    <p>Create an API token in the admin area and send it as a bearer token. In development an administrator is assumed.</p>
    #{code("bash", ~s|curl -H 'Authorization: Bearer $MIRROR_TOKEN' http://localhost:4000/api/v1/pages/1002|)}
    <h2 id="endpoints">Endpoints</h2>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Endpoint</th><th class="confluenceTh">Description</th></tr>
        <tr><td class="confluenceTd"><code>GET /api/v1/spaces</code></td><td class="confluenceTd">All mirrored spaces</td></tr>
        <tr><td class="confluenceTd"><code>GET /api/v1/spaces/:key/pages</code></td><td class="confluenceTd">Pages of a space</td></tr>
        <tr><td class="confluenceTd"><code>GET /api/v1/pages/:id</code></td><td class="confluenceTd">One page with body and labels</td></tr>
        <tr><td class="confluenceTd"><code>GET /api/v1/pages/:id/children</code></td><td class="confluenceTd">Direct children</td></tr>
        <tr><td class="confluenceTd"><code>GET /api/v1/search?cql=…</code></td><td class="confluenceTd">CQL search</td></tr>
        <tr><td class="confluenceTd"><code>GET /wiki/rest/api/content/:id</code></td><td class="confluenceTd">Confluence-compatible representation</td></tr>
      </tbody>
    </table>
    <h2 id="shape">Response shape</h2>
    #{code("json", ~s|{\n  "results": [ { "id": "1002", "type": "page", "title": "Architecture Overview" } ],\n  "start": 0, "limit": 25, "size": 1\n}|)}
    <p>Pagination uses <code>start</code> and <code>limit</code>, like Confluence. Rate limits are reported in <code>X-RateLimit-*</code> headers; a <code>429</code> carries <code>Retry-After</code>.</p>
    """)
  end

  defp deprecated_body do
    doc("""
    #{panel(:error, "Archived page", "<p>This setup is obsolete and only kept for history. Follow #{page_link(1001, "Getting Started")} instead.</p>")}
    <h2 id="old-setup">Old setup</h2>
    #{code("bash", ~s|docker run -p 8090:8090 atlassian/confluence:7.13\n# credentials: admin / admin|)}
    <p>The old procedure relied on a local Confluence instance. The mirror no longer needs one.</p>
    """)
  end

  defp product_home_body do
    doc("""
    #{panel(:info, "Product Hub", "<p>Release notes, roadmap and planning for the platform. Engineering details live in the #{page_link(1002, "Engineering Handbook")}.</p>")}
    <h2 id="latest-release">Latest release</h2>
    <p>#{page_link(2001, "Release 2.0")} — published 1 October 2026.</p>
    <h2 id="pages">Pages</h2>
    #{children_macro([2002])}
    """)
  end

  defp release_body do
    doc("""
    <p><strong>Release 2.0 is live.</strong> The mirror now supports CQL search, webhooks, e-mail notifications and a Confluence-compatible API.</p>
    <h2 id="highlights">Highlights</h2>
    <ul>
      <li>#{lozenge(:success, "NEW")} CQL search on top of Postgres full-text search</li>
      <li>#{lozenge(:success, "NEW")} Signed webhooks for near-instant updates</li>
      <li>#{lozenge(:success, "NEW")} Per-reader rate limits and API tokens</li>
    </ul>
    <h2 id="upgrade">Upgrade notes</h2>
    #{code("bash", ~s|mix ecto.migrate\nmix confluence.sync --mode snapshot|)}
    <p>Architecture details: #{page_link(1002, "Architecture Overview")}. Roadmap: #{page_link(2002, "Roadmap")}.</p>
    """)
  end

  defp roadmap_body do
    doc("""
    <h2 id="q4">Q4 priorities</h2>
    <table class="confluenceTable">
      <tbody>
        <tr><th class="confluenceTh">Theme</th><th class="confluenceTh">Status</th><th class="confluenceTh">Owner</th></tr>
        <tr><td class="confluenceTd">Mirror reliability</td><td class="confluenceTd">#{lozenge(:inprogress, "IN PROGRESS")}</td><td class="confluenceTd">Sam</td></tr>
        <tr><td class="confluenceTd">Search relevance</td><td class="confluenceTd">#{lozenge(:success, "DONE")}</td><td class="confluenceTd">Priya</td></tr>
        <tr><td class="confluenceTd">S3 blob store</td><td class="confluenceTd">#{lozenge(:default, "NEXT")}</td><td class="confluenceTd">Jane</td></tr>
      </tbody>
    </table>
    <p>The same data is available as <a href="/wiki/download/attachments/2002/roadmap.csv?version=1">roadmap.csv</a>.</p>
    #{expand("Deferred items", "<p>Fine-grained permissions per space; public sharing links; PDF export bundles.</p>")}
    """)
  end

  # ---------------------------------------------------------------------------
  # Macro building blocks (export_view markup)
  # ---------------------------------------------------------------------------

  defp panel(kind, title, body) do
    {background, border} = panel_colours(kind)

    doc("""
    <div class="panel" style="background-color: #{background}; border: 1px solid #{border};">
      <div class="panelContent" style="background-color: #{background};">
        <p><strong>#{title}</strong></p>
        #{body}
      </div>
    </div>
    """)
  end

  defp panel_colours(:info), do: {"#deebff", "#0052cc"}
  defp panel_colours(:note), do: {"#eae6ff", "#8777d9"}
  defp panel_colours(:tip), do: {"#e3fcef", "#57d9a3"}
  defp panel_colours(:warning), do: {"#fffae6", "#ffc400"}
  defp panel_colours(:error), do: {"#ffebe6", "#ff5630"}

  defp code(language, source) do
    doc("""
    <div class="code panel pdl" style="border-width: 1px;">
      <div class="codeHeader panelHeader pdl" style="border-bottom-width: 1px;"><b>#{language}</b></div>
      <div class="codeContent panelContent pdl">
        <pre class="syntaxhighlighter-pre" data-syntaxhighlighter-params="brush: #{language}; gutter: false; theme: Confluence">#{html_escape(source)}</pre>
      </div>
    </div>
    """)
  end

  defp expand(title, body) do
    doc("""
    <div class="expand-container">
      <div class="expand-control"><span class="expand-control-icon">▶</span> <span class="expand-control-text">#{title}</span></div>
      <div class="expand-content" style="display: none;">#{body}</div>
    </div>
    """)
  end

  defp lozenge(:success, text), do: lozenge("aui-lozenge-success", text)
  defp lozenge(:inprogress, text), do: lozenge("aui-lozenge-inprogress", text)
  defp lozenge(:moved, text), do: lozenge("aui-lozenge-moved", text)
  defp lozenge(:default, text), do: lozenge("aui-lozenge-default", text)

  defp lozenge(class, text), do: ~s(<span class="aui-lozenge #{class}">#{text}</span>)

  defp children_macro(ids) do
    items =
      Enum.map_join(ids, "\n", fn id ->
        "<li><a href=\"#{page_href(id)}\">#{page_title(id)}</a></li>"
      end)

    ~s(<div class="children-display"><ul class="childpages-macro">#{items}</ul></div>)
  end

  defp gallery(items) do
    figures =
      Enum.map_join(items, "\n", fn {page_id, filename, alt} ->
        ~s(<a class="gallery-image" href="#{attachment_href(page_id, filename)}"><img src="#{attachment_href(page_id, filename)}" alt="#{alt}" /></a>)
      end)

    ~s(<div class="gallery-macro"><div class="gallery">#{figures}</div></div>)
  end

  defp image(page_id, filename, alt, extra \\ "") do
    ~s(<img class="confluence-embedded-image" src="#{attachment_href(page_id, filename)}" alt="#{alt}" #{extra} />)
  end

  defp excerpt(html), do: ~s(<div class="excerpt-macro">#{html}</div>)

  defp user_link(username, name) do
    ~s(<a class="confluence-userlink" href="#{@base_url}/wiki/people/#{username}" data-username="#{username}">#{name}</a>)
  end

  defp page_link(id, text), do: ~s(<a href="#{page_href(id)}">#{text}</a>)

  defp page_href(id) do
    {space, _space_name, title} = Map.fetch!(@page_index, id)
    encoded = title |> String.replace(" ", "+")
    "/wiki/spaces/#{space}/pages/#{id}/#{encoded}"
  end

  defp page_title(id), do: @page_index |> Map.fetch!(id) |> elem(2)

  defp attachment_href(page_id, filename),
    do: "/wiki/download/attachments/#{page_id}/#{filename}?version=1"

  defp doc(html), do: String.trim(html)

  # ---------------------------------------------------------------------------
  # DTO builders
  # ---------------------------------------------------------------------------

  defp page(id, space_key, parent_id, title, body_export, labels, opts) do
    updated_at = Keyword.get(opts, :updated_at, ~U[2026-10-18 09:30:00Z])
    author = Keyword.get(opts, :author, "Jane Doe")

    %{
      id: id,
      type: Keyword.get(opts, :type, "page"),
      status: Keyword.get(opts, :status, "current"),
      title: title,
      space_key: space_key,
      parent_id: parent_id,
      version: %{
        number: Keyword.get(opts, :version, 1),
        message: Keyword.get(opts, :message),
        when: updated_at,
        by: %{display_name: author, account_id: account_id(author)}
      },
      body: %{storage: Keyword.get(opts, :storage, body_export), export_view: body_export},
      labels: labels,
      url: "#{@base_url}#{page_href(id)}",
      created_at: Keyword.get(opts, :created_at, ~U[2025-01-12 10:00:00Z]),
      updated_at: updated_at
    }
  end

  defp properties_storage(storage, rows) do
    table =
      Enum.map_join(rows, fn {key, value} ->
        "<tr><th class=\"confluenceTh\">#{key}</th><td class=\"confluenceTd\">#{value}</td></tr>"
      end)

    storage <>
      """
      <ac:structured-macro ac:name="pageproperties" ac:schema-version="1">
        <ac:rich-text-body>
          <table><tbody>#{table}</tbody></table>
        </ac:rich-text-body>
      </ac:structured-macro>
      """
  end

  defp account_id(name) do
    "557058:" <> (name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "."))
  end

  defp member(name) do
    %{email: email(name), account_id: account_id(name), display_name: name}
  end

  defp email(name) do
    local = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, ".")
    local <> "@demo.atlassian.net"
  end

  defp attachment(id, page_id, filename, media_type, content) do
    %{
      id: id,
      page_id: page_id,
      filename: filename,
      media_type: media_type,
      byte_size: byte_size(content),
      version: 1,
      download_url: "/wiki/download/attachments/#{page_id}/#{filename}?version=1",
      updated_at: ~U[2026-10-10 12:00:00Z],
      content: content
    }
  end

  # ---------------------------------------------------------------------------
  # Attachment payloads
  # ---------------------------------------------------------------------------

  defp diagram_svg do
    doc(~S"""
    <svg xmlns="http://www.w3.org/2000/svg" width="760" height="220" viewBox="0 0 760 220" role="img" aria-label="Confluence mirror architecture">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#172554"/><stop offset="100%" stop-color="#0f172a"/>
        </linearGradient>
        <linearGradient id="box" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#1d4ed8"/><stop offset="100%" stop-color="#1e3a8a"/>
        </linearGradient>
      </defs>
      <rect width="760" height="220" rx="16" fill="url(#bg)"/>
      <g font-family="Inter, Helvetica, Arial, sans-serif" text-anchor="middle">
        <rect x="30" y="70" width="150" height="80" rx="10" fill="url(#box)"/>
        <text x="105" y="105" fill="#e0e7ff" font-size="15" font-weight="600">Confluence</text>
        <text x="105" y="128" fill="#bfdbfe" font-size="12">REST API</text>
        <rect x="305" y="55" width="150" height="110" rx="10" fill="#0ea5e9"/>
        <text x="380" y="92" fill="#082f49" font-size="15" font-weight="700">Sync</text>
        <text x="380" y="113" fill="#082f49" font-size="12">rate limited</text>
        <text x="380" y="132" fill="#082f49" font-size="12">audited</text>
        <rect x="580" y="55" width="150" height="110" rx="10" fill="#22c55e"/>
        <text x="655" y="92" fill="#052e16" font-size="15" font-weight="700">Mirror</text>
        <text x="655" y="113" fill="#052e16" font-size="12">Postgres + files</text>
        <text x="655" y="132" fill="#052e16" font-size="12">CQL search</text>
        <path d="M180 110 H300" stroke="#93c5fd" stroke-width="3" marker-end="url(#arrow)"/>
        <path d="M455 110 H575" stroke="#86efac" stroke-width="3" marker-end="url(#arrow2)"/>
        <text x="240" y="98" fill="#bfdbfe" font-size="11">export_view</text>
        <text x="515" y="98" fill="#bbf7d0" font-size="11">upsert</text>
      </g>
      <defs>
        <marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#93c5fd"/></marker>
        <marker id="arrow2" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#86efac"/></marker>
      </defs>
    </svg>
    """)
  end

  defp architecture_csv do
    """
    stage,component,store
    poll,HttpSource,confluence
    render,Renderer,none
    index,Postgres,tsvector
    blobs,LocalStore,filesystem
    """
  end

  defp roadmap_csv do
    """
    quarter,theme,status,owner
    Q4-2026,Mirror reliability,in progress,Sam
    Q4-2026,Search relevance,done,Priya
    Q1-2027,S3 blob store,next,Jane
    """
  end

  defp notes_md do
    """
    # Mirror notes

    - Export view markup is kept verbatim.
    - Internal links are rewritten; unmirrored links point back to Confluence.
    - Attachments live outside Postgres.
    """
  end

  # A tiny, dependency-free PNG encoder for the demo screenshot: a blue/green
  # gradient, so the gallery and image macros show something real.
  defp screenshot_png do
    width = 480
    height = 240

    scanlines =
      for y <- 0..(height - 1), into: <<>> do
        pixels =
          for x <- 0..(width - 1), into: <<>> do
            <<30 + trunc(x / width * 90)::8, 90 + trunc(y / height * 120)::8,
              200 - trunc(x / width * 80)::8>>
          end

        <<0, pixels::binary>>
      end

    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<0x89, "PNG\r\n", 0x1A, "\n">> <>
      png_chunk("IHDR", ihdr) <>
      png_chunk("IDAT", :zlib.compress(scanlines)) <> png_chunk("IEND", "")
  end

  defp png_chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
  end

  defp sample_pdf do
    """
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
    4 0 obj<</Length 58>>stream
    BT /F1 16 Tf 40 120 Td (Confluence Mirror PDF) Tj ET
    endstream
    endobj
    5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
    """
  end

  @doc """
  Read restrictions per page id, as Confluence reports them.

  One page is restricted to a group, so the mirror has a realistic case where
  space permissions are not enough to decide access.
  """
  def page_restrictions do
    %{
      1003 => [%{subject_type: "group", subject_key: "confluence-users"}]
    }
  end

  @doc """
  Who may read each space.

  `PROD` is a private space: signed-in members of the product team only. Every
  other space is open, which is what an unrestricted Confluence space means.
  """
  def space_permissions do
    %{
      "PROD" => [
        %{operation: "read", subject_type: "authenticated", subject_key: nil},
        %{operation: "read", subject_type: "group", subject_key: "product-team"}
      ]
    }
  end

  @doc """
  Group membership, as Confluence reports it.

  The same people who write the demo pages are the ones in its groups, so the
  mirror can show an administrator granted by a synced group rather than by a
  local role.
  """
  def group_members do
    %{
      "confluence-admins" => [member("Dana Whitfield"), member("Priya Nair")],
      "confluence-users" => [
        member("Dana Whitfield"),
        member("Jane Doe"),
        member("Priya Nair"),
        member("Sam Rivera")
      ],
      "product-team" => [member("Priya Nair"), member("Sam Rivera")]
    }
  end

  # ---------------------------------------------------------------------------
  # Generated hierarchy: twenty services and a six-level chain under Operations
  # ---------------------------------------------------------------------------

  defp service_pages do
    @service_topics
    |> Enum.with_index()
    |> Enum.map(fn {topic, index} ->
      title = "Service: #{topic}"

      page(
        @first_service_id + index,
        "ENG",
        @operations_id,
        title,
        service_body(title),
        ~w(service runbook),
        version: 2 + index,
        message: "Document #{topic}",
        updated_at: DateTime.add(~U[2026-10-01 08:00:00Z], index * 3600, :second),
        author: "Priya Nair"
      )
    end)
  end

  defp deep_pages do
    @deep_titles
    |> Enum.with_index()
    |> Enum.map(fn {title, index} ->
      parent = if index == 0, do: @operations_id, else: @first_deep_id + index - 1

      page(
        @first_deep_id + index,
        "ENG",
        parent,
        title,
        deep_body(title),
        ~w(platform runbook),
        version: 1 + index,
        message: "Deep hierarchy demo",
        updated_at: DateTime.add(~U[2026-10-02 08:00:00Z], index * 3600, :second),
        author: "Sam Rivera"
      )
    end)
  end

  defp operations_body do
    doc("""
    <h2>Runbooks</h2>
    <p>Every platform service has a runbook. Start with #{page_link(1100, "Service: API Gateway")}.</p>
    <h2>Deep dives</h2>
    <p>Networking lives in the platform chain: #{page_link(1201, "Networking")}.</p>
    """)
  end

  defp service_body(title) do
    doc("""
    <h2>Overview</h2>
    <p><strong>#{html_escape(title)}</strong> is documented under #{page_link(@operations_id, "Operations")}.</p>
    <h2>On-call</h2>
    <p>Primary on-call rotates weekly; escalations follow the platform rota.</p>
    """)
  end

  defp deep_body(title) do
    doc("""
    <h2>Notes</h2>
    <p>#{html_escape(title)} sits one level below its parent in the operations tree.</p>
    <h2>Escalation</h2>
    <p>Escalate to the parent page before opening an incident channel.</p>
    """)
  end
end
