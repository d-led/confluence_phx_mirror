defmodule ConfluencePhxMirror.Sync.PageProperties do
  @moduledoc """
  Extracts key/value pairs from `pageproperties` macros in the storage format.

  Confluence resolves these macros in the browser, so `export_view` does not
  contain the values. The mirror reads the first table inside the macro and
  stores it as data, which lets the mirror render property reports itself.
  """

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
    |> Enum.flat_map(&table_rows/1)
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

  defp table_rows(children) do
    case Floki.find(children, "table") do
      [table | _] -> table |> Floki.find("tr") |> Enum.flat_map(&row/1)
      [] -> []
    end
  end

  defp row({"tr", _attrs, cells}) do
    case Enum.filter(cells, &match?({tag, _, _} when tag in ["th", "td"], &1)) do
      [key | rest] when rest != [] ->
        key = key |> Floki.text() |> String.trim()
        value = rest |> List.first() |> Floki.text() |> String.trim()
        if key == "", do: [], else: [%{key: key, value: value}]

      _ ->
        []
    end
  end

  defp row(_other), do: []

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
