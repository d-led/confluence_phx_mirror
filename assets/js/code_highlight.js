// Syntax highlighting for Confluence's code macro.
//
// Confluence stores the highlighted source as plain text tagged with the
// highlighter brush it would have used, for example:
//
//   <pre class="syntaxhighlighter-pre"
//        data-syntaxhighlighter-params="brush: javascript; gutter: false">
//
// We reuse the brush to pick a highlight.js grammar, so the mirror renders the
// same languages Confluence offers without shipping Confluence's own theme.

import hljs from "highlight.js/lib/core"

import bash from "highlight.js/lib/languages/bash"
import cpp from "highlight.js/lib/languages/cpp"
import csharp from "highlight.js/lib/languages/csharp"
import css from "highlight.js/lib/languages/css"
import diff from "highlight.js/lib/languages/diff"
import elixir from "highlight.js/lib/languages/elixir"
import go from "highlight.js/lib/languages/go"
import java from "highlight.js/lib/languages/java"
import javascript from "highlight.js/lib/languages/javascript"
import json from "highlight.js/lib/languages/json"
import kotlin from "highlight.js/lib/languages/kotlin"
import php from "highlight.js/lib/languages/php"
import python from "highlight.js/lib/languages/python"
import ruby from "highlight.js/lib/languages/ruby"
import rust from "highlight.js/lib/languages/rust"
import shell from "highlight.js/lib/languages/shell"
import sql from "highlight.js/lib/languages/sql"
import swift from "highlight.js/lib/languages/swift"
import typescript from "highlight.js/lib/languages/typescript"
import xml from "highlight.js/lib/languages/xml"
import yaml from "highlight.js/lib/languages/yaml"

const grammars = {
  bash, cpp, csharp, css, diff, elixir, go, java, javascript, json, kotlin,
  php, python, ruby, rust, shell, sql, swift, typescript, xml, yaml
}

for (const [name, grammar] of Object.entries(grammars)) {
  hljs.registerLanguage(name, grammar)
}

// Confluence brush names -> highlight.js grammar names.
const brushes = {
  "c#": "csharp",
  "c++": "cpp",
  bash: "bash",
  c: "cpp",
  console: "bash",
  cs: "csharp",
  csharp: "csharp",
  css: "css",
  diff: "diff",
  elixir: "elixir",
  ex: "elixir",
  exs: "elixir",
  go: "go",
  golang: "go",
  html: "xml",
  java: "java",
  javascript: "javascript",
  js: "javascript",
  json: "json",
  kt: "kotlin",
  kotlin: "kotlin",
  patch: "diff",
  php: "php",
  py: "python",
  python: "python",
  rb: "ruby",
  rs: "rust",
  ruby: "ruby",
  rust: "rust",
  sh: "bash",
  shell: "shell",
  sql: "sql",
  svg: "xml",
  swift: "swift",
  ts: "typescript",
  typescript: "typescript",
  xhtml: "xml",
  xml: "xml",
  yaml: "yaml",
  yml: "yaml",
  zsh: "bash"
}

const brushPattern = /brush:\s*([^;]+)/i

// The brush arrives in one of two shapes: older exports put it in
// `data-syntaxhighlighter-params` (`brush: javascript; gutter: false`), Cloud
// puts it in the macro header as plain text (`<b>javascript</b>`) and drops the
// attribute entirely.
function brushOf(pre) {
  const params = pre.getAttribute("data-syntaxhighlighter-params") || ""
  const fromParams = params.match(brushPattern)?.[1]
  const header = pre.closest(".code.panel")?.querySelector(".codeHeader")?.textContent

  return (fromParams || header || "").trim().toLowerCase()
}

function languageOf(pre) {
  return brushes[brushOf(pre)]
}

/**
 * Highlights every rendered Confluence code block under `root`.
 *
 * Blocks without a known brush (plain text, or a language Confluence supports
 * but we do not bundle) stay as they are. Highlighting is idempotent, so a
 * navigation that re-runs this cannot double-wrap tokens.
 */
export function highlightCode(root = document) {
  const blocks = root.querySelectorAll("pre.syntaxhighlighter-pre:not([data-highlighted])")

  for (const pre of blocks) {
    const language = languageOf(pre)
    if (!language || !hljs.getLanguage(language)) continue

    const source = pre.textContent
    pre.innerHTML = hljs.highlight(source, {language, ignoreIllegals: true}).value
    pre.dataset.highlighted = "yes"
    pre.classList.add("hljs")
  }
}
