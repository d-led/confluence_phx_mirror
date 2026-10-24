defmodule ConfluencePhxMirror.Export.Site.Search do
  @moduledoc """
  The search index an exported site carries.

  One document per page — its title, space, labels, date and the first
  400 characters of its text — written twice on purpose:

    * `assets/search.json` is the index itself, for any tool that wants to read
      the archive;
    * `search.html` carries the same JSON in a `<script type="application/json">`
      block, so the page can search without fetching anything. A folder opened
      from `file://` may not fetch its own files, and an archive that needs a
      server is not a static site.

  The matcher is a few hundred lines of plain JavaScript (`script/0`) that runs
  in the page: it ranks title matches above space and label matches above the
  body, needs every word to match, and tolerates a typed prefix, a word inside
  another word, an in-order subsequence and one typo — the same scale
  `auto-ynab-csv` uses for its own static report.
  """

  alias ConfluencePhxMirror.Export.Site

  @doc """
  One document per page of `plans`, in the order the archive lists them.

  Each document is a map with `id`, `title`, `space`, `space_key`, `type`,
  `updated`, `labels`, `url` (relative to the archive root) and `text`.
  """
  @spec documents([Site.plan()]) :: [map()]
  def documents(plans) do
    Enum.flat_map(plans, fn plan ->
      Enum.map(plan.pages, fn page ->
        %{
          id: page.confluence_id,
          title: page.title,
          space: plan.space.name,
          space_key: plan.space.key,
          type: page.type,
          updated: date(page.external_updated_at),
          labels: page.labels || [],
          url: Site.page_path(plan.space.key, page.confluence_id),
          text: page.text || ""
        }
      end)
    end)
  end

  @doc """
  The index as JSON.

  `<` is written as `\\u003c`: the same bytes are inlined in a `<script>`
  element, and a page whose text contains `</script>` must not be able to close
  it.
  """
  @spec json([map()]) :: String.t()
  def json(documents) do
    documents
    |> JSON.encode!()
    |> String.replace("<", "\\u003c")
  end

  defp date(nil), do: nil
  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  @script ~S"""
  // Search for a static copy of the Confluence mirror.
  //
  // The index is inlined in this page (assets/search.json holds the same
  // documents for other tools), so search needs no server and no network: open
  // the folder and type. Every typed word has to match somewhere; a title
  // weighs more than a space or a label, and those weigh more than the body.

  (function () {
    "use strict";

    var source = document.getElementById("search-index");
    if (!source) return;

    var documents = JSON.parse(source.textContent);
    var entries = documents.map(prepare);
    var input = document.getElementById("search-q");
    var status = document.getElementById("search-status");
    var results = document.getElementById("search-results");

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
    function score(token, candidates) {
      var best = 0;

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

    function search(query) {
      var needles = words(query);
      if (needles.length === 0) return [];

      var hits = [];

      for (var i = 0; i < entries.length; i++) {
        var total = scoreEntry(entries[i], needles);
        if (total > 0) hits.push({entry: entries[i], score: total});
      }

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

      var lowered = text.toLowerCase();
      var at = -1;

      for (var i = 0; i < needles.length && at < 0; i++) {
        at = lowered.indexOf(needles[i]);
      }

      if (at < 0) return text.slice(0, 240);

      var start = Math.max(0, at - 80);
      var end = Math.min(text.length, start + 240);

      return (start > 0 ? "…" : "") + text.slice(start, end) + (end < text.length ? "…" : "");
    }

    function highlight(text, needles) {
      var fragment = document.createDocumentFragment();
      var lowered = text.toLowerCase();
      var ranges = [];

      needles.forEach(function (needle) {
        var at = lowered.indexOf(needle);
        while (at >= 0) {
          ranges.push([at, at + needle.length]);
          at = lowered.indexOf(needle, at + needle.length);
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

    function render(query) {
      var needles = words(query);
      var hits = search(query);

      while (results.firstChild) results.removeChild(results.firstChild);

      if (needles.length === 0) {
        status.textContent =
          documents.length +
          (documents.length === 1 ? " page" : " pages") +
          " in this copy. Type a word to search titles, spaces, labels and text.";
        return;
      }

      if (hits.length === 0) {
        status.textContent = "Nothing matches that.";
        return;
      }

      status.textContent =
        hits.length + (hits.length === 1 ? " page matches." : " pages match.");

      hits.forEach(function (hit) {
        results.appendChild(resultNode(hit.entry.page, needles));
      });
    }

    var initial = "";
    try {
      initial = new URLSearchParams(window.location.search).get("q") || "";
    } catch (noHistoryApi) {
      initial = "";
    }

    input.value = initial;
    render(initial);
    input.focus();

    input.addEventListener("input", function () {
      render(input.value);
    });
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
