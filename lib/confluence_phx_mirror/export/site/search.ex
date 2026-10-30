defmodule ConfluencePhxMirror.Export.Site.Search do
  @moduledoc """
  The search index an exported site carries.

  One document per page — its title, space, labels, date and the first
  400 characters of its text — written twice on purpose:

    * `assets/search.json` is the index itself, for any tool that wants to read
      the archive;
    * `assets/search-index.js` assigns the same JSON to a global, which
      `search.html` loads with a `<script src>` tag: a folder opened from
      `file://` may not fetch its own files, but it does run its own scripts.

  The index loads where a reader asks a question. `search.html` carries it, the
  archive's front page names it in `data-index` and receives it on the first
  keystroke, and every other page carries neither: one index serves the whole
  copy, and a folder of pages should not pay for it on each page a reader opens.

  Both are written **while the export streams**, one space at a time, into a
  temporary file: a site of a hundred thousand pages makes an index that does
  not fit in a small box's memory twice over (once as documents, once as JSON),
  and an archive is not worth an out-of-memory kill.

  The matcher is a few hundred lines of plain JavaScript (`script/0`) that runs
  in the page: it ranks title matches above space and label matches above the
  body, needs every word to match, and tolerates a typed prefix, a word inside
  another word, an in-order subsequence and one typo — the same scale
  `auto-ynab-csv` uses for its own static report. Accents are folded on both
  sides, and a match is marked where it is in the original text.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Export.Site
  alias ConfluencePhxMirror.Mirror.{Page, Space}
  alias ConfluencePhxMirror.Repo

  # The first characters of a page's text that the index carries; the same
  # number the archive used to read with every page's plan.
  @excerpt_chars 400

  @doc """
  Writes the index as JSON to `path`, one space at a time.

  Nothing but one space's rows is held: each document is encoded as it is read
  and appended to the file, and the space's rows are released before the next
  one is asked for.
  """
  @spec write_json(Path.t(), [Space.t()], Scope.t()) :: :ok
  # The path is the spool file the exporter chose, one it made up from
  # `System.tmp_dir!()` and a unique integer; nothing a request carries reaches
  # the filesystem here.
  # sobelow_skip ["Traversal.FileModule"]
  def write_json(path, spaces, %Scope{} = scope) do
    File.open!(path, [:write, :raw, :binary], fn device ->
      IO.binwrite(device, "[")
      Enum.each(spaces, &write_space(device, &1, scope))
      IO.binwrite(device, "]")
    end)

    :ok
  end

  defp write_space(device, space, scope) do
    space
    |> documents(scope)
    |> Enum.each(&write_document(device, &1))
  end

  # The array is written as the documents are read, so every document but the
  # first is preceded by the comma that separates it — and the file's own
  # position is what says which one this is.
  defp write_document(device, document) do
    {:ok, position} = :file.position(device, :cur)
    if position > 1, do: IO.binwrite(device, ",")
    IO.binwrite(device, JSON.encode_to_iodata!(document))
  end

  @doc """
  One document per page of `space`, in the order the archive lists them.

  Each document is a map with `id`, `title`, `space`, `space_key`, `type`,
  `updated`, `labels`, `url` (relative to the archive root) and `text`.
  """
  @spec documents(Space.t(), Scope.t()) :: [map()]
  def documents(%Space{} = space, %Scope{} = scope) do
    from(p in Page,
      as: :page,
      where: p.space_id == ^space.id and is_nil(p.deleted_at),
      order_by: [asc: p.title],
      select: %{
        id: p.confluence_id,
        title: p.title,
        type: p.type,
        updated: p.external_updated_at,
        labels: p.labels,
        text: fragment("left(coalesce(?, ''), ?)", p.body_text, ^@excerpt_chars)
      }
    )
    |> Authorization.restrict_pages(scope)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        id: row.id,
        title: row.title,
        space: space.name,
        space_key: space.key,
        type: row.type,
        updated: date(row.updated),
        labels: row.labels || [],
        url: Site.page_path(space.key, row.id),
        text: row.text || ""
      }
    end)
  end

  defp date(nil), do: nil
  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  @script ~S"""
  // Search for a static copy of the Confluence mirror.
  //
  // The index arrives as `assets/search-index.js`, which assigns the same
  // documents `assets/search.json` holds. A script file is what a folder
  // opened from `file://` will run but not fetch, so search works with no
  // server and no network: open the folder and type. Every typed word has to
  // match somewhere; a title weighs more than a space or a label, and those
  // weigh more than the body.

  (function () {
    "use strict";

    // Written by `assets/search-index.js`. A page that carries the index loads
    // it before this script; the archive's front page names it in `data-index`
    // and gets it on the first keystroke, so opening the folder to browse the
    // spaces costs nothing until somebody searches.
    var documents = window.__MIRROR_SEARCH__ || [];
    var loaded = !!window.__MIRROR_SEARCH__;
    var entries = documents.map(prepare);
    var source = document.currentScript
      ? document.currentScript.getAttribute("data-index")
      : null;

    // `search.html` has a box of its own, every page has one in the header, and
    // here the two ask one question.
    var pageInput = document.getElementById("search-q");
    var header = document.querySelector('form[role="search"] input[name="q"]');
    var boxes = [pageInput, header].filter(Boolean);

    var status = document.getElementById("search-status");
    var progress = document.getElementById("search-progress");
    var results = document.getElementById("search-results");
    var spinner = document.getElementById("search-spinner");

    // Where results take the place of something else: the front page swaps its
    // space cards for them.
    var surface = document.getElementById("search-surface");
    var cards = document.getElementById("front-spaces");

    var MAX_RESULTS = 50;

    function normalise(value) {
      return String(value == null ? "" : value)
        .toLowerCase()
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .replace(/ß/g, "ss");
    }

    function words(value) {
      return normalise(value)
        .split(/[^\p{L}\p{N}]+/u)
        .filter(function (word) {
          return word.length > 0;
        });
    }

    // The text folded the way a query is folded, with a way back: a match is
    // found in the folded copy and marked in the original one, so "uber" marks
    // "über" instead of finding nothing to underline. Folding can change a
    // character's length — "ß" folds to two letters, a combining accent to none
    // — so every folded character remembers the range it came from.
    function folding(text) {
      var folded = "";
      var spans = [];
      var at = 0;

      Array.from(text).forEach(function (character) {
        var piece = normalise(character);

        for (var i = 0; i < piece.length; i++) {
          spans.push([at, at + character.length]);
        }

        folded += piece;
        at += character.length;
      });

      return {
        text: folded,
        start: function (index) {
          return index < spans.length ? spans[index][0] : at;
        },
        end: function (index) {
          return index < spans.length ? spans[index][1] : at;
        }
      };
    }

    function isSubsequence(needle, haystack) {
      var found = 0;
      for (var i = 0; i < haystack.length; i++) {
        if (haystack[i] === needle[found]) found++;
        if (found === needle.length) return true;
      }
      return false;
    }

    function editDistance(a, b) {
      var row = [];
      for (var j = 0; j <= b.length; j++) row.push(j);

      for (var i = 1; i <= a.length; i++) {
        var previous = row[0];
        row[0] = i;
        for (var k = 1; k <= b.length; k++) {
          var current = row[k];
          row[k] = Math.min(
            row[k] + 1,
            row[k - 1] + 1,
            previous + (a[i - 1] === b[k - 1] ? 0 : 1)
          );
          previous = current;
        }
      }

      return row[b.length];
    }

    // 100 exact, 80 prefix, 60 substring, 40 in-order subsequence, 30 one typo.
    function score(token, candidates) {      var best = 0;

      for (var i = 0; i < candidates.length; i++) {
        var candidate = candidates[i];

        if (candidate === token) return 100;
        if (candidate.indexOf(token) === 0) best = Math.max(best, 80);
        else if (candidate.indexOf(token) >= 0) best = Math.max(best, 60);
        else if (isSubsequence(token, candidate)) best = Math.max(best, 40);
        else if (
          token.length >= 4 &&
          Math.abs(candidate.length - token.length) <= 1 &&
          editDistance(token, candidate) <= 1
        ) {
          best = Math.max(best, 30);
        }
      }

      return best;
    }

    function prepare(page) {
      return {
        page: page,
        title: words(page.title),
        space: words(page.space + " " + page.space_key),
        labels: words((page.labels || []).join(" ")),
        text: words(page.text)
      };
    }

    function scoreEntry(entry, needles) {
      var total = 0;

      for (var i = 0; i < needles.length; i++) {
        var needle = needles[i];
        var best = Math.max(
          score(needle, entry.title) * 3,
          score(needle, entry.space) * 2,
          score(needle, entry.labels) * 2,
          score(needle, entry.text)
        );

        if (best === 0) return 0;
        total += best;
      }

      return total;
    }

    // Best first, and no more than the page can usefully show.
    function rank(hits) {
      hits.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return String(b.entry.page.updated || "").localeCompare(
          String(a.entry.page.updated || "")
        );
      });

      return hits.slice(0, MAX_RESULTS);
    }

    // The part of the text around the first match, so the result shows why it
    // is a result.
    function snippet(text, needles) {
      if (!text) return "";

      var folded = folding(text);
      var at = -1;

      for (var i = 0; i < needles.length && at < 0; i++) {
        at = folded.text.indexOf(needles[i]);
      }

      if (at < 0) return text.slice(0, 240);

      var start = Math.max(0, folded.start(at) - 80);
      var end = Math.min(text.length, start + 240);

      return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
    }

    function highlight(text, needles) {
      var fragment = document.createDocumentFragment();
      var folded = folding(text);
      var ranges = [];

      needles.forEach(function (needle) {
        var at = folded.text.indexOf(needle);
        while (at >= 0) {
          ranges.push([folded.start(at), folded.end(at + needle.length - 1)]);
          at = folded.text.indexOf(needle, at + needle.length);
        }
      });

      ranges.sort(function (a, b) {
        return a[0] - b[0];
      });

      var cursor = 0;

      ranges.forEach(function (range) {
        var start = Math.max(range[0], cursor);
        var end = range[1];
        if (end <= cursor) return;

        if (start > cursor) {
          fragment.appendChild(document.createTextNode(text.slice(cursor, start)));
        }

        var mark = document.createElement("mark");
        mark.className = "bg-transparent font-semibold text-primary";
        mark.textContent = text.slice(start, end);
        fragment.appendChild(mark);

        cursor = end;
      });

      if (cursor < text.length) {
        fragment.appendChild(document.createTextNode(text.slice(cursor)));
      }

      return fragment;
    }

    // `page` is one index document; `document` is the DOM's.
    function resultNode(page, needles) {
      var item = document.createElement("li");
      item.className = "rounded-xl border border-base-300/70 bg-base-100 p-4";

      var link = document.createElement("a");
      link.className = "text-sm font-semibold text-primary hover:underline";
      link.href = page.url;
      link.textContent = page.title;
      item.appendChild(link);

      var meta = document.createElement("p");
      meta.className = "mt-1 text-[11px] uppercase tracking-wide text-base-content/70";
      meta.textContent = [
        page.space,
        page.type === "blogpost" ? "blog post" : "page",
        page.updated
      ]
        .filter(Boolean)
        .join(" · ");
      item.appendChild(meta);

      var text = snippet(page.text || "", needles);
      if (text) {
        var body = document.createElement("p");
        body.className = "mt-2 text-xs text-base-content/70";
        body.appendChild(highlight(text, needles));
        item.appendChild(body);
      }

      return item;
    }

    function catalogue() {
      // Nothing to count until the index is here, and a field nobody has typed
      // in does not need a promise of a corpus.
      if (!loaded) return "";

      return (
        documents.length +
        (documents.length === 1 ? " page" : " pages") +
        " in this copy. Type a word to search titles, spaces, labels and text."
      );
    }

    function clear() {
      while (results.firstChild) results.removeChild(results.firstChild);
    }

    function show(hits, needles) {
      var best = rank(hits);
      clear();

      if (best.length === 0) {
        status.textContent = "Nothing matches that.";
        return;
      }

      // The list stops at MAX_RESULTS; the count does not, so a broad query
      // says how much it left out rather than pretending to have found fifty.
      status.textContent =
        best.length === hits.length
          ? hits.length + (hits.length === 1 ? " page matches." : " pages match.")
          : "The first " + best.length + " of " + hits.length + " matching pages.";

      best.forEach(function (hit) {
        results.appendChild(resultNode(hit.entry.page, needles));
      });
    }

    // --- running a query ------------------------------------------------------
    //
    // A whole-site index is six figures of documents, and scoring it is not
    // instant. Two things keep that from feeling like a broken field: the scan
    // waits for a pause in typing, and it runs in slices, so the page keeps
    // painting a "Searching… n%" status while it works. A newer query cancels
    // the slices of the older one, so a result can never land under the wrong
    // text.

    var SETTLE_MS = 150;
    var SLICE_MS = 12;
    var settling = null;
    var scanning = null;
    var current = "";

    function busy(on) {
      if (spinner) spinner.hidden = !on;
      results.setAttribute("aria-busy", on ? "true" : "false");
      if (!on) progress.textContent = "";
    }

    // The running commentary: visible, but never read out. A screen reader
    // hears the result, not eighty percentage updates.
    function working(text) {
      progress.textContent = text;
      status.textContent = "";
    }

    function cancelScan() {
      if (scanning) scanning.cancelled = true;
      scanning = null;
    }

    // `hidden` is what the markup asks for, but Tailwind's grid on the cards
    // outranks it, so the swap is an inline display value — cleared back to
    // whatever the stylesheet says when the box empties.
    function reveal(element, visible) {
      if (element) element.style.display = visible ? "" : "none";
    }

    // The front page names the index but does not ship it: a reader who opens
    // the folder to look at the spaces should not wait for a scan they never
    // asked for. The first question fetches it, once; after that it is memory.
    var asking = false;

    function fetchIndex() {
      // One fetch, however many keystrokes arrive while it is on its way.
      if (asking) return;

      if (!source) {
        status.textContent = "This copy carries no search index.";
        return;
      }

      asking = true;
      busy(true);
      working("Loading the index…");

      var script = document.createElement("script");
      script.src = source;
      script.async = false;
      script.onload = function () {
        documents = window.__MIRROR_SEARCH__ || [];
        entries = documents.map(prepare);
        loaded = true;
        asking = false;

        // The box may have grown, or been emptied, while the index arrived, so
        // the question asked now is the one answered — not the one that
        // started the fetch.
        run(current);
      };
      script.onerror = function () {
        asking = false;
        busy(false);
        status.textContent = "The index is missing from this copy.";
      };
      document.head.appendChild(script);
    }

    function run(query) {
      current = query;
      cancelScan();

      var needles = words(query);
      var searching = needles.length > 0;

      // Where the results take the place of something else, the swap follows
      // the box rather than the result: the reader sees the search begin.
      reveal(surface, searching);
      reveal(cards, !searching);

      if (!searching) {
        busy(false);
        clear();
        status.textContent = catalogue();
        return;
      }

      if (!loaded) {
        fetchIndex();
        return;
      }

      startScan(needles);
    }

    function startScan(needles) {
      var scan = {cancelled: false};
      var hits = [];
      var at = 0;

      scanning = scan;
      busy(true);
      working("Searching…");

      function slice() {
        if (scan.cancelled) return;

        var until = Date.now() + SLICE_MS;

        while (at < entries.length && Date.now() < until) {
          var entry = entries[at++];
          var total = scoreEntry(entry, needles);
          if (total > 0) hits.push({entry: entry, score: total});
        }

        if (at < entries.length) {
          working("Searching… " + Math.round((at / entries.length) * 100) + "%");
          window.setTimeout(slice, 0);
          return;
        }

        scanning = null;
        busy(false);
        show(hits, needles);
      }

      window.setTimeout(slice, 0);
    }

    function settle(query) {
      if (settling) window.clearTimeout(settling);

      cancelScan();

      if (words(query).length === 0) {
        settling = null;
        run(query);
        return;
      }

      busy(true);
      working("Searching…");

      settling = window.setTimeout(function () {
        settling = null;
        run(query);
      }, SETTLE_MS);
    }

    var initial = "";
    try {
      initial = new URLSearchParams(window.location.search).get("q") || "";
    } catch (noHistoryApi) {
      initial = "";
    }

    boxes.forEach(function (box) {
      box.value = initial;
    });

    if (pageInput) pageInput.focus();

    // Whichever box the reader types in, the other follows, and every keystroke
    // only settles the scan: a word typed at speed is scanned once, not once
    // per letter.
    boxes.forEach(function (box) {
      box.addEventListener("input", function () {
        boxes.forEach(function (other) {
          if (other !== box) other.value = box.value;
        });

        settle(box.value);
      });
    });

    // With the index in hand Enter has nothing left to carry: the box has
    // already searched, and submitting would reload the page to parse the index
    // a second time. Pages without this script keep the untouched form, which
    // takes the reader to `search.html?q=` — and that page searches as soon as
    // it has its index.
    if (header && header.form) {
      header.form.addEventListener("submit", function (event) {
        event.preventDefault();
        settle(header.value);
      });
    }

    run(initial);
  })();
  """

  @doc """
  The matcher and the result list, as one self-contained script.

  Written without template literals: it is a `~S` heredoc, so what is in the
  source is exactly what an archive gets.
  """
  @spec script() :: String.t()
  def script, do: @script
end
