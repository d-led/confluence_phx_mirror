defmodule ConfluencePhxMirror.Sync.DynamicContent.Marker do
  @moduledoc """
  Turns a macro as Confluence *stores* it into the marker the mirror expands.

  A page records its macros in the storage format:

      <ac:structured-macro ac:name="children" ac:schema-version="2">
        <ac:parameter ac:name="sort">creation</ac:parameter>
        <ac:parameter ac:name="maxResults">25</ac:parameter>
      </ac:structured-macro>

  `export_view` sometimes carries that element unexpanded — and that is the only
  place a static mirror learns a page asked for a macro at all. For a macro the
  mirror draws, this turns the element into the `mirror-macro` div that
  `DynamicContent` resolves; for one it does not, the caller keeps saying so.

  Parameter names stay Confluence's, in the attribute spelling the mirror uses:
  `minLevel` becomes `data-min-level`. The few the mirror calls something else
  are in `@renamed`, because "the headings a report shows" is a column list and
  "maximum results" is a limit, and a renderer should read the word it means.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Registry

  @renamed %{
    "headings" => "columns",
    "max" => "limit",
    "maxresults" => "limit",
    "pagesize" => "limit"
  }

  @doc """
  The marker for a stored macro, or `:error` when the mirror cannot draw it.

      iex> build("toc", [{"minLevel", "2"}])
      {:ok, {"div", [{"class", "mirror-macro"}, {"data-macro", "toc"}, {"data-min-level", "2"}], []}}

      iex> build("jira", [])
      :error
  """
  @spec build(String.t(), [{String.t(), String.t()}]) :: {:ok, Floki.html_node()} | :error
  def build(name, parameters) do
    case Registry.fetch(String.downcase(name)) do
      {:ok, _renderer} -> {:ok, marker(Registry.canonical(String.downcase(name)), parameters)}
      :error -> :error
    end
  end

  @doc "Whether the mirror can draw the macro named `name`."
  @spec drawable?(String.t()) :: boolean()
  def drawable?(name), do: match?({:ok, _}, Registry.fetch(String.downcase(name)))

  defp marker(name, parameters) do
    {"div", [{"class", "mirror-macro"}, {"data-macro", name} | data(parameters)], []}
  end

  defp data(parameters) do
    for {name, value} <- parameters, do: {"data-" <> attribute(name), value}
  end

  # `minLevel` -> `min-level`, unless the mirror has a word of its own for it.
  defp attribute(name) do
    Map.get(
      @renamed,
      String.downcase(name),
      name |> String.replace(~r/(?<=[a-z0-9])(?=[A-Z])/, "-") |> String.downcase()
    )
  end
end
