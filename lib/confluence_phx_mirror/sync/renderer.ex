defmodule ConfluencePhxMirror.Sync.Renderer do
  @moduledoc """
  Turns Confluence's `export_view` HTML into mirror-ready HTML.

  Confluence already renders macros in `export_view` (panels, code, expand,
  status, TOC, Jira issues, includes…), so the mirror keeps that markup
  verbatim. What this module changes is exactly the part that must change for
  a mirror:

    * links to mirrored pages become internal mirror links (cross-linking),
    * links to pages that were not mirrored stay absolute back to Confluence,
      so a reader can always open the original,
    * attachment links and images point at the mirrored blob,
    * Confluence's emoticons become the characters they stand for,
    * active content (`script`, event handler attributes, `javascript:` URLs)
      is removed, because the mirror renders third-party HTML.

  Every rewritten link is returned as a link record so the sync can store
  backlinks. The renderer is pure: it never queries the database.
  """

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync.{Adf, Emoticons, MacroPlaceholder, VendorMacros}
  alias ConfluencePhxMirror.Sync.DynamicContent.Marker

  @type page_ref :: %{space_key: String.t(), confluence_id: integer(), slug: String.t()}

  @type attachment_ref :: %{
          confluence_id: integer(),
          page_confluence_id: integer(),
          space_key: String.t(),
          filename: String.t()
        }

  # What a page needs to be rendered: where it came from, where links should
  # point, and how to resolve a file it does not own. `:page` is accepted and
  # not read — links come from `:pages`, files from `:attachment_lookup` — so a
  # caller holding only the source's DTO (the desktop tool, which renders a body
  # before the row exists) can produce the same markup the server does.
  @doc """
  Which rules drew a body.

  A page is re-read when Confluence's version moves, and never otherwise — but
  a rule that decides how a body is *drawn* can change while the page it drew
  has not changed at all. This number is stored on the page, so raising it
  re-reads every page once, on the next sync, instead of waiting for somebody
  to edit each one.

  Raise it whenever the output changes for a body that is already mirrored.
  """
  @spec revision() :: pos_integer()

  # 2: a decision list keeps the state its export view drops (`Sync.Adf`).
  # 3: a whiteboard or database embed names and links to itself instead of
  #    staying the unknown-macro placeholder the export view carries.
  # 4: a whiteboard is drawn from its document (`Sync.Whiteboard`), or apologises
  #    with a link when it cannot be.
  # 5: a macro's parameters are found wherever it is declared — inside another
  #    macro's body included — so an embed that sat in an excerpt keeps them.
  # 6: the link under a whiteboard or database is a caption, not its address.
  # 7: a drawn whiteboard is a figure whose picture opens a viewer, where it can
  #    be zoomed, panned and saved.
  # 8: a database names the database it embeds instead of saying "a database".
  # 9: a panel draws the icon its storage declares, which the export view drops.
  # 10: a labels list is drawn from the mirror's own labels instead of staying the
  #     widget for a macro Confluence will not expand for a reader.
  # 11: a parameter that names a page, a person or a file carries that name, so an
  #     include finds the page it was pointed at instead of naming none.
  # 12: a user profile names its person and their pages instead of staying the
  #     widget for a macro Confluence will not expand for a reader.
  # 13: an html macro shows the markup it holds, through the sanitiser, instead of
  #     the widget — the body it wraps was being dropped with the placeholder.
  # 14: an undrawn macro is named in words a reader knows ("a tasks report"), not
  #     by the key the page stores.
  # 15: a labels list is the site's four alphabetical columns, not one flat list.
  # 16: the task and decision reports are drawn from the items inside page bodies
  #     instead of staying the widget for a macro Confluence will not expand.
  # 17: a reported task says its words, not the tick Confluence draws beside them.
  # 18: a code block that asks for a gutter gets its line numbers beside it.
  # 19: a contributor's name is the link to their page here, not a dead word.
  # 20: a face is served from the mirror's own blob store, instead of pointing at
  #     the site — which does not serve it, and redirects the reader to Gravatar.
  # 21: a page in a space the deployment publishes names nobody in its body, so
  #     the one copy served to every reader is the stranger's copy.
  # 22: a macro the mirror cannot draw shows what it carried — its own text or
  #     the body it wrapped — instead of dropping it behind the note.
  # 23: `anchor` and `profile-picture` are drawn: the first records the name a
  #     `#link` lands on, the second serves the face the mirror keeps.
  # 24: a panel's icon sits inside its first paragraph, so the panel is the same
  #     height as the one beside it instead of one line taller.
  # 25: a panel an author coloured keeps that colour (it was drawn as the kind an
  #     ADF panel declared, badge and all), a panel with its own glyph drops the
  #     generic badge, and a decision's state is a mark rather than the word the
  #     mirror had been printing.
  # 26: a body that names a space links to the mirror's own space screen when the
  #     mirror holds it, instead of sending the reader to the site.
  # 27: a body's mention of a person is that person's page here, and a label name
  #     is the mirror's label catalogue.
  # 28: a label Confluence scoped to a space (`/wiki/label/KEY/NAME`) is the same
  #     catalogue, and no longer a link to the site.
  # 29: a mention or a label address that carries a query string (`?ref=confluence`)
  #     is the same person and the same catalogue, not a link to the site.
  # 30: a widget connector is the page it names — a frame when the deployment
  #     allows that host, and always the address under it.
  # 31: a widget connector's address is read from the reference it is stored as,
  #     so a body mirrored under 30 (where the address read as empty) is re-read
  #     instead of keeping "the macro names no address".
  # 32: a roadmap planner is drawn from the plan the editor stores in it — its
  #     lanes, bars and markers on the plan's own timeline — instead of staying
  #     the widget for a macro Confluence will not expand for a reader.
  def revision, do: 32

  @type context :: %{
          optional(:page) => ConfluencePhxMirror.Mirror.Page.t(),
          required(:space_key) => String.t(),
          required(:base_url) => String.t() | nil,
          optional(:storage) => String.t() | nil,
          optional(:pages) => %{integer() => page_ref()},
          optional(:attachments) => %{{integer(), String.t()} => attachment_ref()},
          optional(:attachment_lookup) => (integer(), String.t() -> attachment_ref() | nil),
          optional(:space_lookup) => (String.t() -> ConfluencePhxMirror.Mirror.Space.t() | nil),
          optional(:person_lookup) => (String.t() -> map() | nil)
        }

  @type link :: %{
          href: String.t(),
          kind: String.t(),
          target_confluence_id: integer() | nil,
          label: String.t() | nil
        }

  @type result :: %{html: String.t(), links: [link()], text: String.t()}

  # iframe/object/embed are not stripped here: they are replaced by an honest
  # placeholder in `replace_live_only_content/2`, which runs later.
  @unsafe_elements ~w(script applet form input button)
  @url_attributes ~w(href src action formaction poster)

  # Macros Confluence renders in the browser (Jira issues, page tree, Connect
  # and Forge apps) do not survive the REST API: the export carries an iframe or
  # an unexpanded macro. A static mirror cannot run them, so it says so instead
  # of pretending — inventing output would be a lie about the source. The keys
  # are Confluence's own `ac:name` values; the ones the mirror can draw never
  # reach this map (`Sync.DynamicContent.Marker` intercepts them first).
  @live_only_elements ~w(iframe object embed)

  # The keys are the `ac:name` values a page actually stores, which is not always
  # the name Confluence's own documentation gives the macro: the tasks report is
  # `tasks-report` in storage, and a map that knew only `tasks-report-macro` made
  # the widget say "The tasks-report macro" instead of naming the thing.
  @macro_labels %{
    "jira" => "a Jira issues search",
    "jiraissues" => "a Jira issues list",
    "jirachart" => "a Jira chart",
    "advanced-roadmaps-plan-macro" => "an Advanced Roadmaps plan",
    "space-attachments" => "a space attachments list",
    "spaces-list" => "a spaces list",
    "livesearch" => "a live search box",
    "gadget" => "an external gadget",
    "iframe" => "an embedded page",
    "rss" => "an RSS feed",
    "roadmap" => "a roadmap",
    "chart" => "a chart",
    "gallery" => "an image gallery"
  }

  # A macro whose body *is* its answer: the excerpt a page declares for others to
  # include. There is nothing to draw and nothing to explain, so the words stay —
  # wrapped the way Confluence's own export view wraps them, so that an excerpt
  # include on another page finds the region whether or not the export expanded
  # this macro for us.
  @body_is_the_answer ~w(excerpt)

  # Floki's parser drops text runs that are only whitespace, but the exporter
  # relies on them for the visible space between inline elements (two status
  # lozenges would touch, `<strong>` next to `<em>` would read "onetwo").
  # Each run travels through the parse as a marker and comes back verbatim.
  @inter_tag_space ~r/(?<=>)\s+(?=<)/u
  @space_marker ~r/\x{E000}([A-Za-z0-9_-]+)\x{E001}/u

  @doc """
  Sanitises and rewrites `html` for `context`.

  Returns the rewritten HTML, the links found in it and its plain text.
  """
  @spec render(String.t() | nil, context()) :: result()
  def render(nil, _context), do: %{html: "", links: [], text: ""}
  def render("", _context), do: %{html: "", links: [], text: ""}

  def render(html, context) when is_binary(html) do
    nodes =
      html
      |> mark_spaces()
      |> Floki.parse_fragment!()
      |> remove_unsafe_elements()
      |> drop_undeclared_macro_chrome(context)
      |> Adf.repair(context)
      |> expand_raw_html(context)

    # Links are collected *before* rewriting, while hrefs still carry the
    # Confluence identity the link table needs.
    links =
      nodes
      |> Floki.find("a[href]")
      |> Enum.map(&link_record(&1, context))
      |> Enum.uniq()

    rewritten =
      nodes
      |> traverse_and_rewrite(context)
      |> code_gutters()
      |> replace_live_only_content(context)
      |> Floki.raw_html()
      |> Emoticons.characters()
      |> restore_spaces()

    %{html: rewritten, links: links, text: plain_text(rewritten)}
  end

  @doc "Plain text of rendered HTML, used for Postgres full-text search."
  def plain_text(html) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> drop_text_excluded()
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def plain_text(_), do: ""

  # Confluence's `export_view` inlines its own colour rules in `<style>` blocks.
  # Those rules are kept in the rendered HTML (they style the page), but their
  # text content is not prose: leaving it in `body_text` puts
  # `[data-colorid=…]{color:#97a0af}` into previews and search snippets.
  @text_excluded_elements ~w(style script noscript head title template)

  defp drop_text_excluded(nodes) do
    Enum.reduce(@text_excluded_elements, nodes, &Floki.filter_out(&2, &1))
  end

  defp remove_unsafe_elements(nodes) do
    Enum.reduce(@unsafe_elements, nodes, &Floki.filter_out(&2, &1))
  end

  # Confluence's HTML macro *is* its body: the author hands the renderer markup
  # and the site draws it. Two things make that awkward.
  #
  # The export view does not carry the macro at all — it leaves a picture of one —
  # so the markup is read from the storage, where the page declares it, and matched
  # to the picture in reading order, the way a panel's icon already is. And the
  # markup is the author's, not the mirror's, so it goes through the same sanitiser
  # as the rest of the page: spliced here, before the attribute pass, because by
  # the time a macro is drawn that pass has already run.
  @raw_html_macros ~w(html)

  defp expand_raw_html(nodes, context) do
    {expanded, _unused} = splice_raw_html(nodes, raw_html_bodies(context))
    expanded
  end

  # One body per declaration, in reading order.
  defp raw_html_bodies(%{storage: storage}) when is_binary(storage) do
    storage
    |> Floki.parse_fragment!()
    |> elements()
    |> Enum.filter(&raw_html?/1)
    |> Enum.map(fn {_tag, _attrs, children} -> plain_text_body(children) end)
  end

  defp raw_html_bodies(_context), do: []

  defp splice_raw_html(nodes, bodies), do: Enum.flat_map_reduce(nodes, bodies, &splice_node/2)

  defp splice_node({"ac:structured-macro", attrs, children}, bodies) do
    if raw_html_macro?(attribute(attrs, "ac:name")) do
      drawn_body(bodies, children)
    else
      {children, rest} = splice_raw_html(children, bodies)
      {[{"ac:structured-macro", attrs, children}], rest}
    end
  end

  defp splice_node({"img", attrs, _children} = node, bodies) do
    if raw_html_macro?(placeholder_macro(attrs)),
      do: drawn_body(bodies, []),
      else: {[node], bodies}
  end

  defp splice_node({tag, attrs, children}, bodies) do
    {children, rest} = splice_raw_html(children, bodies)
    {[{tag, attrs, children}], rest}
  end

  defp splice_node(other, bodies), do: {[other], bodies}

  # The declared body first; an element that carries its own is the fallback, for
  # a source whose export view did expand the macro after all.
  defp drawn_body([body | rest], _children), do: {drawn(body), rest}
  defp drawn_body([], children), do: {drawn(plain_text_body(children)), []}

  defp drawn(body) do
    body |> Floki.parse_fragment!() |> remove_unsafe_elements()
  end

  defp plain_text_body(children) do
    children
    |> Enum.flat_map(fn
      {"ac:plain-text-body", _attrs, text} -> [Floki.text(text)]
      _other -> []
    end)
    |> Enum.join()
  end

  defp raw_html?({"ac:structured-macro", attrs, _children}),
    do: raw_html_macro?(attribute(attrs, "ac:name"))

  defp raw_html?(_element), do: false

  defp raw_html_macro?(name) when is_binary(name),
    do: String.downcase(String.trim(name)) in @raw_html_macros

  defp raw_html_macro?(_name), do: false

  # What a family of macro chrome is allowed to draw. `export_view` is HTML, and
  # HTML cannot tell a macro from a paragraph pasted to look like one: Confluence
  # keeps such markup in the page's storage, refuses to *render* it — its page
  # comes from the editor's document, where that markup is prose — and a mirror
  # that trusts the HTML draws a panel the site never showed.
  #
  # The storage is where a macro is declared (`ac:structured-macro ac:name=…`),
  # so each family may draw as many blocks as the storage declares macros that
  # produce it, in reading order. Past that, the wrapper goes and the words
  # inside it stay, which is exactly what Confluence shows.
  # Not listed: `excerpt-macro`. An excerpt is not decoration — another page
  # includes it, and the marker is how `DynamicContent.Include` finds the words
  # to include, so removing it would break a page that consumes this one.
  @chrome_families [
    {"confluence-information-macro", ["tip", "note", "info", "warning"]},
    {"code", ["code", "noformat"]},
    {"panel", ["panel"]},
    {"aui-lozenge", ["status"]},
    {"status-macro", ["status"]},
    {"expand-container", ["expand"]},
    {"toc-macro", ["toc"]}
  ]

  # The modern editor does not always write a structured macro: a panel, a
  # status or a code block inserted from its palette is stored as an ADF node
  # (Confluence keeps the editor's document inline), and those are macros all
  # the same. Counted here by the name the export gives their chrome.
  @adf_names %{
    "panel" => "panel",
    "status" => "status",
    "codeBlock" => "code",
    "expand" => "expand",
    "expandable" => "expand"
  }
  # The inside of a chrome block: these carry no meaning of their own and only
  # appear within a family, so they go when their wrapper goes.
  @chrome_parts ~w(panelContent panelHeader codeContent codeHeader pdl
                   confluence-information-macro-body confluence-information-macro-icon
                   expand-content expand-control expand-control-icon expand-control-text) ++ []

  defp drop_undeclared_macro_chrome(nodes, context) do
    case declared_macros(context) do
      # A body from a source that carries no storage cannot be judged this way,
      # so it keeps every block it has rather than losing what may be earned.
      nil ->
        nodes

      names ->
        # The panels carry icons the export view drops, and the queue is what
        # says which panel showed which glyph: declarations and drawn panels are
        # matched by order alone. A panel with no icon still holds its place.
        budget = {chrome_budget(names), panel_icons(context)}
        {budgeted, _left} = budget_chrome(nodes, budget)
        budgeted
    end
  end

  defp declared_macros(%{storage: storage}) when is_binary(storage) do
    storage
    |> Floki.parse_fragment!()
    |> elements()
    |> Enum.flat_map(&declared_name/1)
  end

  defp declared_macros(_context), do: nil

  defp declared_name({"ac:structured-macro", attrs, _children}) do
    case attribute(attrs, "ac:name") do
      name when is_binary(name) -> [name |> String.trim() |> String.downcase()]
      _no_name -> []
    end
  end

  defp declared_name({"ac:adf-node", attrs, _children}) do
    case attribute(attrs, "type") do
      type when is_binary(type) -> List.wrap(Map.get(@adf_names, type))
      _no_type -> []
    end
  end

  defp declared_name(_element), do: []

  defp chrome_budget(names) do
    Map.new(@chrome_families, fn {token, earned_by} ->
      {token, Enum.count(names, &(&1 in earned_by))}
    end)
  end

  # One entry per panel the storage declares, in reading order: the emoji a
  # classic panel names, or nil — a panel without one still takes its turn in
  # the queue, because the export view's panels and the storage's declarations
  # are matched by order alone. A typed panel's tone is `Sync.Adf.Panel`'s half.
  defp panel_icons(context) do
    context
    |> declared_panels()
    |> Enum.map(&panel_icon/1)
  end

  # A classic panel names its emoji twice: `panelIcon` is the shortcode,
  # `panelIconId` the Atlassian id or a Twemoji code point.
  defp panel_icon({_tag, _attrs, children}) do
    parameters = panel_parameters(children)

    Emoticons.glyph(parameters["panelIconId"]) ||
      Emoticons.glyph(parameters["panelIcon"])
  end

  defp declared_panels(%{storage: storage}) when is_binary(storage) do
    storage
    |> Floki.parse_fragment!()
    |> elements()
    |> Enum.filter(&declared_panel?/1)
  end

  defp declared_panels(_context), do: []

  defp declared_panel?({"ac:structured-macro", attrs, _children}) do
    case attribute(attrs, "ac:name") do
      name when is_binary(name) -> String.downcase(String.trim(name)) == "panel"
      _no_name -> false
    end
  end

  # A panel the editor stored as an ADF node still takes its place in the queue,
  # so the two kinds of panel cannot shift each other's icons.
  defp declared_panel?({"ac:adf-node", attrs, _children}), do: attribute(attrs, "type") == "panel"

  defp declared_panel?(_element), do: false

  defp panel_parameters(children) do
    children
    |> Enum.filter(&match?({"ac:parameter", _, _}, &1))
    |> Map.new(fn {"ac:parameter", attrs, value} ->
      {attribute(attrs, "ac:name"), value |> Floki.text() |> String.trim()}
    end)
  end

  defp take_icon("panel", [icon | rest]), do: {icon, rest}
  defp take_icon(_token, icons), do: {nil, icons}

  # Reading order matters: a declared macro earns the first block of its family
  # in the document, and a paste that happens to come earlier keeps nothing.
  defp budget_chrome(nodes, budget), do: Enum.flat_map_reduce(nodes, budget, &budget_node/2)

  defp budget_node({tag, attrs, children}, {budget, icons} = state) do
    case chrome_token(attrs) do
      nil ->
        {children, state} = budget_chrome(children, state)
        {[{tag, attrs, children}], state}

      token ->
        case Map.get(budget, token, 0) do
          left when left > 0 ->
            {children, {budget, icons}} =
              budget_chrome(children, {Map.put(budget, token, left - 1), icons})

            {icon, icons} = take_icon(token, icons)
            {[{tag, with_glyph(attrs, icon), with_icon(children, icon)}], {budget, icons}}

          _undeclared ->
            # The wrapper goes and its words stay: what Confluence shows.
            unwrap_chrome(children, {budget, icons})
        end
    end
  end

  defp budget_node(other, state), do: {[other], state}

  # Confluence draws a panel's emoji at the start of its body, beside the words.
  defp with_icon(children, nil), do: children

  defp with_icon(children, glyph) do
    put_icon(children, {"span", [{"class", "mirror-panel-icon"}], [glyph]})
  end

  # A panel that declares a glyph draws *that* glyph, not the badge the mirror
  # draws for a typed panel: two icons on one card is not what the site shows.
  # The class is the renderer's word for "this panel has an icon of its own",
  # and the stylesheet drops the badge (and its room) because of it.
  defp with_glyph(attrs, nil), do: attrs

  defp with_glyph(attrs, _glyph) do
    Enum.map(attrs, fn
      {"class", value} -> {"class", value <> " mirror-panel-iconic"}
      other -> other
    end)
  end

  defp put_icon(children, node) do
    case Enum.split_while(children, &(not panel_content?(&1))) do
      {before, [content | after_content]} ->
        before ++ [prepend_child(content, node)] ++ after_content

      {_none, []} ->
        [node | children]
    end
  end

  defp panel_content?({_tag, attrs, _children}) do
    attrs
    |> attribute("class")
    |> to_string()
    |> String.split()
    |> Enum.member?("panelContent")
  end

  defp panel_content?(_node), do: false

  # The glyph belongs beside the first *words*, and the words are a block inside
  # the body: a sibling `<span>` before it would be the body's first child, so
  # the margin rule meant for the paragraph would miss the paragraph and the
  # panel would sit one line lower — and taller — than the one beside it.
  @blocks ~w(p div ul ol blockquote table h1 h2 h3 h4 h5 h6 pre)

  defp prepend_child({tag, attrs, [first | rest]}, node) do
    case first do
      {inner, _attrs, _children} when inner in @blocks ->
        {tag, attrs, [prepend_child(first, node) | rest]}

      _text_or_nothing ->
        {tag, attrs, [node, first | rest]}
    end
  end

  defp prepend_child({tag, attrs, children}, node), do: {tag, attrs, [node | children]}

  # Inside a block that is going away, so is every wrapper that belongs to it.
  defp unwrap_chrome(children, state) do
    Enum.flat_map_reduce(children, state, fn
      {tag, attrs, inner}, state ->
        if chrome_wrapper?(attrs),
          do: unwrap_chrome(inner, state),
          else: budget_node({tag, attrs, inner}, state)

      other, state ->
        {[other], state}
    end)
  end

  defp chrome_wrapper?(attrs) do
    classes = class_tokens(attrs)
    Enum.any?(@chrome_parts, &(&1 in classes))
  end

  defp chrome_token(attrs) do
    classes = class_tokens(attrs)

    Enum.find_value(@chrome_families, fn {token, _earned_by} ->
      if token in classes, do: token
    end)
  end

  defp class_tokens(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {_name, value} when is_binary(value) -> String.split(value)
      _none -> []
    end
  end

  # Confluence's code macro takes a `gutter` setting — line numbers or not — and
  # the export view keeps it: `data-syntaxhighlighter-params="brush: sql; gutter: true; …"`.
  # So the mirror honours the author's choice instead of making one for them.
  #
  # The numbers are a second `pre` beside the code rather than markup inside it:
  # the tokens a highlighter paints cross line boundaries, and cutting them apart
  # at every newline would be a parser's job for a cosmetic win. Two columns share
  # one line height, and the code scrolls sideways without taking its numbers.
  defp code_gutters(nodes) do
    Floki.traverse_and_update(nodes, fn
      {"pre", attrs, children} = pre ->
        if numbers?(attrs), do: with_gutter(pre, children), else: pre

      other ->
        other
    end)
  end

  defp numbers?(attrs) do
    params = attribute(attrs, "data-syntaxhighlighter-params") || ""

    has_class?(attrs, "syntaxhighlighter-pre") and
      match?([_], Regex.run(~r/gutter:\s*true/i, params))
  end

  defp with_gutter(pre, children) do
    numbers =
      children
      |> Floki.text(sep: "")
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {_line, number} -> Integer.to_string(number) end)

    {"div", [{"class", "mirror-code"}],
     [{"pre", [{"class", "mirror-code-gutter"}, {"aria-hidden", "true"}], [numbers]}, pre]}
  end

  defp replace_live_only_content(nodes, context) do
    {replaced, _declarations} = replace_nodes(nodes, declarations_by_name(context), context)

    replaced
  end

  # A cursor, not a plain walk: when a macro the mirror *can* draw arrives as
  # nothing but a picture of itself, its parameters have to be read from the
  # storage — in document order, the nth picture matching the nth declaration.
  defp replace_nodes(nodes, declarations, context) when is_list(nodes) do
    Enum.flat_map_reduce(nodes, declarations, fn node, seen ->
      replace_node(node, seen, context)
    end)
  end

  defp replace_node({tag, _attrs, _children}, declarations, context)
       when tag in @live_only_elements,
       do: {List.wrap(unavailable("this embedded content", context)), declarations}

  # Confluence's `unknown-macro` placeholder is a *picture of a macro*, drawn by
  # the site under the reader's own session. Copied into a mirror it is a broken
  # image where a macro used to be — and in a window with no session it is a
  # blank box.
  #
  # So the name in the picture is looked up, not taken at face value: a macro the
  # mirror draws becomes the marker the storage-format path would have built,
  # with the parameters the storage declares (the picture carries the name and
  # nothing else). Everything else becomes the widget the renderer uses for a
  # macro it cannot draw.
  defp replace_node({"img", attrs, _children} = node, declarations, context) do
    case placeholder_macro(attrs) do
      nil ->
        {[node], declarations}

      name ->
        {declaration, declarations} = declared(declarations, name)

        case Marker.build(name, declaration.parameters) do
          {:ok, marker} ->
            {[marker], declarations}

          :error ->
            {MacroPlaceholder.widget(name,
               label: label(name),
               url: external_url(context),
               content: MacroPlaceholder.source(declaration.text)
             ), declarations}
        end
    end
  end

  defp replace_node({"ac:structured-macro", attrs, children} = node, declarations, context) do
    # Children first: a macro may wrap other macros (a tab holding a panel), and
    # the wrapping macro is drawn from children that are already mirror-ready —
    # which is what the bottom-up traversal this replaced gave it.
    {children, declarations} = replace_nodes(children, declarations, context)

    case List.keyfind(attrs, "ac:name", 0) do
      {"ac:name", name} when name in @body_is_the_answer ->
        {List.wrap(excerpt_region(children)), declarations}

      {"ac:name", name} ->
        parameters = parameters(children)
        body = rich_text_body(children)

        drawn =
          case VendorMacros.draw(name, Map.new(parameters), body) do
            {:ok, drawn} -> drawn
            :error -> unresolved(name, parameters, body, plain_text_body(children), context)
          end

        {List.wrap(drawn), declarations}

      nil ->
        {[node], declarations}
    end
  end

  # Any other element may still hold one of the above inside it.
  defp replace_node({tag, attrs, children}, declarations, context) do
    {children, declarations} = replace_nodes(children, declarations, context)

    {[{tag, attrs, children}], declarations}
  end

  defp replace_node(other, declarations, _context), do: {[other], declarations}

  # The parameters each macro name declares, in document order. The storage is
  # walked as the tree it is, not scanned: a macro may sit inside another, or
  # inside a wrapper between the two — a whiteboard in an excerpt's body is the
  # real case — and anything that looks for closing tags textually loses the
  # nesting and every declaration after it.
  defp declarations_by_name(%{storage: storage}) when is_binary(storage) do
    storage
    |> Floki.parse_fragment!()
    |> elements()
    |> Enum.flat_map(&declaration/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp declarations_by_name(_context), do: %{}

  defp declaration({"ac:structured-macro", attrs, children}) do
    case attribute(attrs, "ac:name") do
      name when is_binary(name) ->
        [
          {String.downcase(name),
           %{parameters: parameters(children), text: plain_text_body(children)}}
        ]

      _no_name ->
        []
    end
  end

  defp declaration(_element), do: []

  # Every element of a parsed document, in document order: a parent before its
  # children. Nothing here depends on which tags wrap which — that is the point.
  defp elements(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &elements/1)
  defp elements({tag, attrs, children}), do: [{tag, attrs, children} | elements(children)]
  defp elements(_text), do: []

  defp attribute(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp declared(declarations, name) do
    key = String.downcase(name)

    case Map.get(declarations, key, []) do
      [declaration | rest] -> {declaration, Map.put(declarations, key, rest)}
      [] -> {%{parameters: [], text: ""}, declarations}
    end
  end

  defp macro_label(name), do: Map.get(@macro_labels, name, "the #{name} macro")

  # Which macro a Confluence placeholder image stood for, or nil for an ordinary
  # picture. The name is in the query (`…/placeholder/unknown-macro?name=…`), and
  # the class says the same thing when the URL has been rewritten.
  defp placeholder_macro(attrs) do
    src = attrs |> List.keyfind("src", 0) |> src_or_empty()

    if has_class?(attrs, "wysiwyg-unknown-macro") or
         String.contains?(src, "placeholder/unknown-macro") do
      placeholder_macro_name(src)
    end
  end

  defp src_or_empty({_key, value}), do: value
  defp src_or_empty(nil), do: ""

  defp placeholder_macro_name(src) do
    with [_all, query] <- String.split(src, "?", parts: 2),
         %{"name" => name} when name != "" <- URI.decode_query(query) do
      name
    else
      _no_name -> "unknown"
    end
  end

  # A macro the mirror cannot draw still has content. Most of these are
  # containers — a tab whose body holds the page somebody wrote — so the content
  # goes inside the box, with the note after it, rather than being replaced by
  # the note.
  defp unresolved(name, parameters, body, text, context) do
    case Marker.build(name, parameters) do
      {:ok, marker} ->
        marker

      :error ->
        MacroPlaceholder.widget(name,
          label: label(name),
          url: external_url(context),
          content: body ++ MacroPlaceholder.source(text)
        )
    end
  end

  defp label(name), do: VendorMacros.label(name) || macro_label(name)

  defp external_url(%{page: %{external_url: url}}) when is_binary(url) and url != "", do: url
  defp external_url(_context), do: nil

  # The excerpt region, in the shape Confluence's export view uses for one.
  defp excerpt_region(children) do
    [{"div", [{"class", "excerpt-macro"}], rich_text_body(children)}]
  end

  defp rich_text_body(children) do
    Enum.flat_map(children, fn
      {"ac:rich-text-body", _attrs, inner} -> inner
      _other -> []
    end)
  end

  # The options a stored macro carries, in the order the page wrote them.
  defp parameters(children) do
    Enum.flat_map(children, &List.wrap(parameter(&1)))
  end

  # A parameter's value is not always text. Confluence writes a reference as a
  # typed element — `<ri:page ri:content-title="…"/>`, `<ri:user ri:account-id="…"/>`
  # — and `<ac:parameter ac:name="">` around one carries no name at all: the kind
  # of thing it names *is* the name ("page", "user"). Read for its text alone, such
  # a parameter is empty, and the macro ends up naming nothing.
  defp parameter({"ac:parameter", attrs, value}) do
    case attribute(attrs, "ac:name") do
      name when is_binary(name) ->
        case reference(value) do
          {kind, named} -> {kind_name(name, kind), named}
          nil -> {name, value |> Floki.text() |> String.trim()}
        end

      _no_name ->
        nil
    end
  end

  defp parameter(_other), do: nil

  # Which attribute of a typed reference carries the identity, best first. A page
  # is named by its title before its id because that is the word `include` reads.
  @references %{
    "ri:page" => ["ri:content-title", "ri:content-id"],
    "ri:user" => ["ri:account-id", "ri:username", "ri:userkey"],
    "ri:attachment" => ["ri:filename"],
    "ri:space" => ["ri:space-key"],
    # A widget connector's address is a reference too, and its element carries no
    # text: read for text alone, the marker had no address and every widget from
    # the editor said it named none.
    "ri:url" => ["ri:value"]
  }

  defp reference(nodes) when is_list(nodes), do: Enum.find_value(nodes, &reference/1)

  defp reference({tag, attrs, _children}) do
    with keys when is_list(keys) <- Map.get(@references, tag),
         value when is_binary(value) <- Enum.find_value(keys, &attribute(attrs, &1)) do
      {tag, value}
    end
  end

  defp reference(_node), do: nil

  defp kind_name("", kind), do: kind_word(kind)
  defp kind_name(name, _kind), do: name

  defp kind_word("ri:page"), do: "page"
  defp kind_word("ri:user"), do: "user"
  defp kind_word("ri:attachment"), do: "attachment"
  defp kind_word("ri:space"), do: "space"
  defp kind_word("ri:url"), do: "url"
  defp kind_word(_other), do: ""

  # The link is written as a plain Confluence URL so the usual anchor rewriting
  # turns it into an absolute link back to the original page.
  defp unavailable(what, context) do
    {"div", [{"class", "mirror-unavailable"}],
     [
       {"p", [],
        [
          {"strong", [], ["Sorry, this content cannot be shown in the static mirror."]},
          " ",
          what |> String.capitalize(),
          " is rendered live by Confluence."
        ]},
       {"p", [], ["Open the ", original_link(context), " to see it there."]}
     ]}
  end

  defp original_link(%{page: %{external_url: url}}) when is_binary(url) and url != "" do
    {"a", [{"href", url}], ["original page"]}
  end

  defp original_link(_context), do: "original Confluence page"

  defp mark_spaces(html) do
    Regex.replace(@inter_tag_space, html, fn run ->
      "\uE000" <> Base.url_encode64(run, padding: false) <> "\uE001"
    end)
  end

  defp restore_spaces(html) do
    Regex.replace(@space_marker, html, fn _, encoded ->
      Base.url_decode64!(encoded, padding: false)
    end)
  end

  defp traverse_and_rewrite(nodes, context) do
    Floki.traverse_and_update(nodes, fn
      {"a", attrs, children} ->
        {"a", rewrite_anchor(attrs, children, context), children}

      {"img", attrs, children} ->
        case Emoticons.from_image(attrs) do
          nil -> {"img", rewrite_image(attrs, context), children}
          glyph -> glyph
        end

      {"div", attrs, children} ->
        if has_class?(attrs, "expand-container") do
          expand_to_details(children)
        else
          {"div", sanitise_attributes(attrs), children}
        end

      {tag, attrs, children} ->
        {tag, sanitise_attributes(attrs), children}

      other ->
        other
    end)
  end

  # Confluence's expand macro is a div pair toggled by JavaScript. A mirror has
  # no editing JavaScript, so it becomes the native, accessible equivalent: a
  # closed <details> with the original control text as <summary>.
  defp expand_to_details(children) do
    control = find_child(children, "expand-control")
    content = find_child(children, "expand-content")

    if control && content do
      {"details", [{"class", "expand-container"}],
       [
         {"summary", [{"class", "expand-control"}], reject_icon(control)},
         {"div", [{"class", "expand-content"}], content}
       ]}
    else
      {"div", [{"class", "expand-container"}], children}
    end
  end

  defp find_child(children, class) do
    Enum.find_value(children, fn
      {"div", attrs, kids} -> if has_class?(attrs, class), do: kids
      _ -> nil
    end)
  end

  defp reject_icon(children) do
    Enum.reject(children, fn
      {"span", attrs, _kids} -> has_class?(attrs, "expand-control-icon")
      _ -> false
    end)
  end

  defp has_class?(attrs, class) do
    case List.keyfind(attrs, "class", 0) do
      {"class", value} -> class in String.split(value)
      nil -> false
    end
  end

  defp rewrite_anchor(attrs, children, context) do
    case Floki.attribute({"a", attrs, children}, "href") do
      [href | _] ->
        case classify_href(href, context) do
          {:internal, path} -> attrs |> put_attribute("href", path) |> put_rel(context)
          {:attachment, path} -> put_attribute(attrs, "href", path)
          {:external, url} -> attrs |> put_attribute("href", url) |> put_rel(context)
        end

      [] ->
        attrs
    end
  end

  defp rewrite_image(attrs, context) do
    attrs =
      case Floki.attribute({"img", attrs, []}, "src") do
        [src | _] ->
          case classify_href(src, context) do
            {:attachment, path} -> put_attribute(attrs, "src", path)
            {:internal, path} -> put_attribute(attrs, "src", path)
            {:external, url} -> put_attribute(attrs, "src", url)
          end

        [] ->
          attrs
      end

    # A page can carry a dozen screenshots; lazy keeps the first paint cheap and
    # async keeps decoding off the main thread.
    attrs
    |> put_default("alt", "")
    |> put_default("loading", "lazy")
    |> put_default("decoding", "async")
    |> sanitise_attributes()
  end

  defp put_rel(attrs, context) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        if absolute_url?(href) and not same_origin?(href, context.base_url) do
          attrs
          |> put_default("rel", "noopener noreferrer")
          |> put_default("target", "_blank")
        else
          attrs
        end

      nil ->
        attrs
    end
  end

  defp put_default(attrs, name, value) do
    if List.keymember?(attrs, name, 0), do: attrs, else: [{name, value} | attrs]
  end

  defp put_attribute(attrs, name, value) do
    [{name, value} | List.keydelete(attrs, name, 0)]
  end

  @doc """
  Rewrites the attachment links of an already rendered body it can now answer.

  A page may be rendered before the file it links exists in the mirror — the
  owner arrives later in the same run — and the first pass leaves that link
  pointing at the source. This is the second chance: only `href` and `src` on
  anchors and images are touched, and only when the answer is now a mirrored
  attachment, so everything else about the body stays exactly as it was.
  """
  @spec relink_attachments(String.t(), map()) :: String.t()
  def relink_attachments(html, context) when is_binary(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.traverse_and_update(fn
      {"a", attrs, children} -> {"a", relink(attrs, "href", context), children}
      {"img", attrs, children} -> {"img", relink(attrs, "src", context), children}
      node -> node
    end)
    |> Floki.raw_html()
    |> restore_spaces()
  end

  defp relink(attrs, attribute, context) do
    case List.keyfind(attrs, attribute, 0) do
      {_, value} ->
        case classify_href(value, context) do
          {:attachment, path} -> put_attribute(attrs, attribute, path)
          _other -> attrs
        end

      nil ->
        attrs
    end
  end

  @doc false
  # Classifies a raw href into what the mirror should do with it:
  #
  # * `{:internal, path}`   – mirrored page or in-page anchor
  # * `{:attachment, path}` – mirrored attachment, rewritten to the blob route
  # * `{:external, url}`    – absolute URL back to the original / the web
  def classify_href(href, context) do
    href = String.trim(href || "")

    cond do
      href == "" ->
        {:external, href}

      String.starts_with?(href, "#") ->
        {:internal, href}

      unsafe_scheme?(href) ->
        {:external, "#"}

      page_id = page_id_from_path(href) ->
        page_link(page_id, fragment(href), context)

      space_key = space_key_from_path(href) ->
        space_link(space_key, href, context)

      account_id = person_account(href) ->
        person_link(account_id, href, context)

      account_id = avatar_account(href) ->
        {:attachment, people_avatar_path(account_id)}

      attachment = attachment_from_path(href) ->
        attachment_link(attachment, href, context)

      label_name = label_name_from_path(href) ->
        {:internal, URLs.label_path(label_name)}

      true ->
        {:external, absolutise(href, context)}
    end
  end

  # A mention is the site's people page for one account, and the mirror has a page
  # per author — so the name stays a link here, where a reader of a closed
  # deployment has an account. Only when the mirror holds a page for that person:
  # an author it has never seen keeps the site's link, as a page nobody mirrored
  # does.
  defp person_account(href) do
    case Regex.run(~r{/(?:wiki/)?people/([^/?#]+)(?:[?#].*)?$}, href) do
      [_, account_id] -> URI.decode(account_id)
      nil -> nil
    end
  end

  defp person_link(account_id, href, context) do
    case person_of(account_id, context) do
      %{} -> {:internal, URLs.person_path(account_id)}
      _ -> {:external, absolutise(href, context)}
    end
  end

  defp person_of(account_id, context) do
    case Map.get(context, :person_lookup) do
      lookup when is_function(lookup, 1) -> lookup.(account_id)
      _ -> nil
    end
  end

  # A label is a catalogue the mirror draws from its own pages, so the name is a
  # link here whatever the label holds: a label no mirrored page carries answers
  # with an empty catalogue, which is a true thing to say about this mirror.
  # Confluence writes a label scoped to a space as `/label/KEY/NAME`; the
  # catalogue is the label's either way, so the key is dropped.
  defp label_name_from_path(href) do
    case Regex.run(~r{/(?:wiki/)?labels?/(?:[\w~.-]+/)?([^/?#]+)(?:[?#].*)?$}, href) do
      [_, name] -> URI.decode(name)
      nil -> nil
    end
  end

  # A face is not a file the site serves: `/aa-avatar/<account-id>` answers 302,
  # to Gravatar or to Atlassian's initials service. Left in a page, the path sends
  # every reader to two third parties and shows nothing once the site is
  # unreachable. The bytes are kept in the blob store beside the attachments, and
  # this is the route that serves them back to the reader who may see the page.
  defp avatar_account(href) do
    case Regex.run(~r{/aa-avatar/([^/?#]+)}, href) do
      [_, account_id] -> account_id
      nil -> nil
    end
  end

  defp people_avatar_path(account_id) do
    "/people/" <> URI.encode_www_form(account_id) <> "/avatar"
  end

  # A body names a space at the site's own address — `/wiki/spaces/KEY` today,
  # `/wiki/display/KEY` before that. The mirror has that screen, so the name stays
  # a link inside it: left alone it sends a reader off the mirror to a site they
  # may have no account on. Only when the mirror holds the space, which is the
  # rule a page link follows too — a key nobody mirrored keeps its site link.
  defp space_key_from_path(href) do
    case Regex.run(~r{/(?:spaces|display)/([^/?#]+)(?:/overview)?/?$}, href) do
      [_, key] -> URI.decode(key)
      nil -> nil
    end
  end

  defp space_link(key, href, context) do
    case space_of(key, context) do
      %{key: space_key} -> {:internal, URLs.space_path(space_key)}
      _ -> {:external, absolutise(href, context)}
    end
  end

  defp space_of(key, context) do
    case Map.get(context, :space_lookup) do
      lookup when is_function(lookup, 1) -> lookup.(key)
      _ -> nil
    end
  end

  defp page_link(confluence_id, fragment, context) do
    case get_in(context, [:pages, confluence_id]) do
      %{space_key: space_key, confluence_id: id, slug: slug} ->
        {:internal, with_fragment(URLs.page_path(space_key, id, slug), fragment)}

      nil ->
        {:external,
         absolutise("/pages/viewpage.action?pageId=#{confluence_id}", context)
         |> with_fragment(fragment)}
    end
  end

  # A link to a page can name a place inside it, and a table of contents is a page
  # full of exactly that. The fragment is kept verbatim because the ids it names
  # are the ones the export already put on its headings (`Title-Heading`);
  # dropping it turns every entry into a link back to the page the reader is
  # already reading, where nothing appears to happen when it is pressed.
  defp fragment(href) do
    case String.split(href, "#", parts: 2) do
      [_path, fragment] when fragment != "" -> fragment
      _no_fragment -> nil
    end
  end

  defp with_fragment(path, nil), do: path
  defp with_fragment(path, fragment), do: path <> "#" <> fragment

  # Confluence's download path names the content the file hangs off, and that is
  # not always the page: a screenshot pasted into a comment is
  # `/download/attachments/9306117/…`, naming the comment, and a page that links
  # a colleague's file names *that* page. The map is keyed by the owner and the
  # filename, so a page file and a comment file of the same name cannot be
  # mistaken for one another, and the mirror still serves both under the page
  # they belong to.
  defp attachment_link({owner_id, filename}, href, context) do
    case find_attachment(owner_id, filename, context) do
      %{confluence_id: attachment_id, page_confluence_id: page_id, space_key: space_key} ->
        {:attachment, URLs.attachment_path(space_key, page_id, attachment_id, filename)}

      _ ->
        {:external, absolutise(href, context)}
    end
  end

  # The page's own files are already in the context. One it does not own is
  # asked of the mirror, because a download URL names the owner and a link to
  # another page's file is as internal as a link to another page — when the
  # mirror holds it, which the lookup answers.
  defp find_attachment(owner_id, filename, context) do
    get_in(context, [:attachments, {owner_id, filename}]) ||
      ask_mirror(owner_id, filename, context)
  end

  defp ask_mirror(owner_id, filename, context) do
    case Map.get(context, :attachment_lookup) do
      lookup when is_function(lookup, 2) -> lookup.(owner_id, filename)
      _ -> nil
    end
  end

  @doc false
  def page_id_from_path(href) do
    patterns = [
      ~r{/pages/(\d+)(?:/|\?|$|#)},
      ~r{[?&]pageId=(\d+)}
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, href) do
        [_, id | _] -> String.to_integer(id)
        _ -> nil
      end
    end)
  end

  @doc false
  def attachment_from_path(href) do
    patterns = [
      ~r{/download/(?:thumbnails|attachments)/(\d+)/([^?#]+)},
      ~r{/download/attachments/(\d+)/([^?#]+)}
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, href) do
        [_, page_id, filename | _] -> {String.to_integer(page_id), URI.decode(filename)}
        _ -> nil
      end
    end)
  end

  defp unsafe_scheme?(href) do
    downcased = href |> to_string() |> String.trim() |> String.downcase()

    String.starts_with?(downcased, "javascript:") or
      String.starts_with?(downcased, "vbscript:") or
      String.starts_with?(downcased, "data:text/html")
  end

  @doc false
  def absolutise(href, %{base_url: base_url}) do
    cond do
      href == "" -> href
      String.starts_with?(href, "#") -> href
      absolute_url?(href) -> href
      is_nil(base_url) -> href
      String.starts_with?(href, "/") -> base_url |> origin() |> Kernel.<>(href)
      true -> base_url |> String.trim_trailing("/") |> Kernel.<>("/") |> Kernel.<>(href)
    end
  end

  defp origin(base_url) do
    uri = URI.parse(base_url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp absolute_url?(href), do: Regex.match?(~r{^[a-zA-Z][a-zA-Z0-9+.-]*:}, href)

  defp same_origin?(href, base_url) do
    with %URI{host: host} when is_binary(host) <- URI.parse(href),
         %URI{host: base_host} when is_binary(base_host) <- URI.parse(base_url || "") do
      String.downcase(host) == String.downcase(base_host)
    else
      _ -> false
    end
  end

  defp link_record(anchor, context) do
    href = anchor |> Floki.attribute("href") |> List.first() || ""
    label = anchor |> Floki.text() |> String.trim() |> String.slice(0, 200)

    case classify_href(href, context) do
      {:internal, path} ->
        %{
          href: path,
          kind: "internal",
          target_confluence_id: page_id_from_path(href),
          label: label
        }

      {:attachment, path} ->
        %{href: path, kind: "attachment", target_confluence_id: nil, label: label}

      {:external, url} ->
        %{
          href: url,
          kind: "external",
          target_confluence_id: page_id_from_path(href),
          label: label
        }
    end
  end

  defp sanitise_attributes(attrs) do
    attrs
    |> Enum.reject(fn {name, _value} -> String.starts_with?(String.downcase(name), "on") end)
    |> Enum.map(fn {name, value} -> {name, sanitise_attribute(name, value)} end)
  end

  defp sanitise_attribute(name, value) when name in @url_attributes do
    if unsafe_scheme?(value), do: "#", else: value
  end

  defp sanitise_attribute(_name, value), do: value
end
