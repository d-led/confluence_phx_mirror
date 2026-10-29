defmodule ConfluencePhxMirror.Sync.PageProperties do
  @moduledoc """
  Extracts key/value pairs from `pageproperties` macros in the storage format.

  Confluence resolves these macros in the browser, so `export_view` does not
  contain the values. The mirror reads the first table inside the macro and
  stores it as data, which lets the mirror render property reports itself.

  ## Two layouts, one table, no parameter

  The macro carries no orientation setting: what a reader calls a *vertical* or
  *horizontal* page properties macro is only the shape of the table the author
  built, and Confluence's own report tells them apart by the heading.

    * A heading **column** makes each row one property —
      `<tr><th>Owner</th><td>Platform</td></tr>`.
    * A heading **row** puts the keys across the top and the values beneath —
      `<tr><th>Owner</th><th>Status</th></tr>` followed by
      `<tr><td>Platform</td><td>Active</td></tr>`.

  Both are read, and reading them is not the same job: a heading-row table read
  as rows of key/value pairs invents a property out of two neighbouring keys and
  drops every value, which is what a report built from it would then publish.
  """

  # A key with no cell beside it still belongs in the table: a ragged row is the
  # author's, and dropping the column would quietly shorten a report.
  @no_value %{heading?: false, text: ""}

  @doc """
  Parses the storage format and returns `[%{key: key, value: value}]`.

  Confluence's macro body is a two-column table (label + value). Rows without a
  key are ignored; duplicated keys keep the first value, matching how a reader
  sees the macro.
  """
  @spec parse(String.t() | nil) :: [%{key: String.t(), value: String.t()}]
  def parse(nil), do: []

  def parse(storage) when is_binary(storage) do
    storage
    |> Floki.parse_fragment!()
    |> find_macros()
    |> Enum.flat_map(&properties/1)
    |> Enum.uniq_by(& &1.key)
  end

  defp find_macros(nodes) do
    {_, macros} =
      Floki.traverse_and_update(nodes, [], fn
        {"ac:structured-macro", attrs, children} = node, acc ->
          if attr(attrs, "ac:name") == "pageproperties" do
            {node, [children | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(macros)
  end

  defp properties(children) do
    case Floki.find(children, "table") do
      [table | _] ->
        table
        |> Floki.find("tr")
        |> Enum.map(&cells/1)
        |> Enum.reject(&(&1 == []))
        |> pairs()

      [] ->
        []
    end
  end

  # Which of the two layouts this table is. Confluence's signal is the heading,
  # and there is no other: a first row whose cells are all headings is the keys
  # seen from above, and one heading followed by values is the keys seen from the
  # left.
  defp pairs([keys, values | _more] = rows) do
    if keys_run_across?(keys), do: horizontal(keys, values), else: vertical(rows)
  end

  defp pairs(rows), do: vertical(rows)

  defp keys_run_across?(cells), do: length(cells) > 1 and Enum.all?(cells, & &1.heading?)

  defp horizontal(keys, values) do
    keys
    |> Enum.with_index()
    |> Enum.flat_map(fn {key, at} -> property(key, Enum.at(values, at, @no_value)) end)
  end

  defp vertical(rows) do
    Enum.flat_map(rows, fn
      [key, value | _ignored] -> property(key, value)
      _one_cell_or_none -> []
    end)
  end

  # A row with no key is not a property; the macro allows one to be left blank.
  defp property(%{text: ""}, _value), do: []

  defp property(key, value), do: [%{key: key.text, value: value.text}]

  defp cells({"tr", _attrs, children}) do
    children
    |> Enum.filter(&match?({tag, _, _} when tag in ["th", "td"], &1))
    |> Enum.map(fn {tag, _attrs, content} ->
      %{heading?: tag == "th", text: text(content)}
    end)
  end

  defp cells(_other), do: []

  # A cell may hold paragraphs, a list, a line break. `sep` is what keeps
  # `<p>Two</p><p>words</p>` from reading as "Twowords".
  defp text(content) do
    content
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
