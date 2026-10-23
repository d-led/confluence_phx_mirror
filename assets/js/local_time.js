// The server renders every instant in UTC, labelled as such, because it cannot
// know the reader's time zone. Only the browser does, so this module rewrites
// each <time> the server marked:
//
//   data-local-time="date|datetime"  replaces the text, e.g. "21 Oct 2026"
//   data-local-title                 localizes the tooltip, for text of our own
//
// The `datetime` attribute holds the instant in UTC and is never touched, so
// what the page claims is what the mirror stored.

const FORMATS = {
  date: {year: "numeric", month: "short", day: "numeric"},
  datetime: {year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"},
  // A log line: the date is the same on every line, so it is not worth a column.
  time: {hour: "2-digit", minute: "2-digit", second: "2-digit"},
  // A tooltip can afford the seconds and the name of the zone.
  title: {dateStyle: "medium", timeStyle: "long"}
}

// `undefined` picks the reader's own locale and zone.
function format(at, kind) {
  return new Intl.DateTimeFormat(undefined, FORMATS[kind]).format(at)
}

export function localizeTimes(root = document) {
  for (const el of root.querySelectorAll("time[datetime]")) {
    const textKind = el.dataset.localTime
    if (!textKind && !el.hasAttribute("data-local-title")) continue

    const at = new Date(el.getAttribute("datetime"))
    // A `datetime` the server did not write is not ours to reformat.
    if (Number.isNaN(at.getTime())) continue

    if (textKind) el.textContent = format(at, textKind)
    el.title = format(at, "title")
  }
}

