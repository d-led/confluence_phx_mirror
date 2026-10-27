defmodule ConfluencePhxMirrorWeb.Admin.SettingsFilter do
  @moduledoc """
  What the settings page shows while an administrator types in its filter.

  The filter is a list's filter like any other on this screen — one box, the
  answer in `?q=` — and it follows the same rule: **every word has to match**.
  `sync pause` reaches the pause switch; `sync theme` matches nothing, because no
  row on this page says both.

  A word is matched against everything a row says: the group it sits in, its
  label, its help, its key and the variable behind it. `sync`, `CM_SYNC`,
  `paused` and `confluence` therefore all lead to the same switch, and the page
  answers "where does this come from?" as well as "where do I change it?".

  Filtering is a matter of what is *shown*, not of what a form holds. A row the
  filter hides keeps its field in the group's form, because a group is saved as
  one transaction and a field the filter took away must not read as "cleared".
  The boot configuration below it is not a form, so a row it drops is dropped.
  """

  @type words :: [String.t()]

  @doc """
  The words a filter query is made of, lowercased.

  No text, or text that is not text at all, is no words — and no words match
  everything.
  """
  @spec words(term()) :: words()
  def words(query) when is_binary(query) do
    query |> String.split() |> Enum.map(&String.downcase/1)
  end

  def words(_no_text), do: []

  @doc "Whether `text` says every one of `words`."
  @spec visible?(String.t(), words()) :: boolean()
  def visible?(text, words) do
    haystack = String.downcase(text)
    Enum.all?(words, &String.contains?(haystack, &1))
  end

  @doc """
  The editable groups, each field and each group marked `:hidden?`.

  Nothing is taken out: a field that is hidden is still the form's, which is what
  lets a filtered group be saved without the rows out of sight changing.
  """
  @spec groups([map()], words()) :: [map()]
  def groups(groups, words) do
    Enum.map(groups, fn group ->
      fields = Enum.map(group.fields, &Map.put(&1, :hidden?, not shown?(group, &1, words)))

      group
      |> Map.put(:fields, fields)
      |> Map.put(:hidden?, Enum.all?(fields, & &1.hidden?))
    end)
  end

  @doc """
  The boot configuration with only the rows and sections the filter keeps.

  These rows answer a question, they are not a form, so a row the filter drops is
  dropped for good — and a section left with no rows goes with it.
  """
  @spec sections([map()], words()) :: [map()]
  def sections(sections, words) do
    sections
    |> Enum.map(fn section ->
      Map.update!(section, :rows, fn rows ->
        Enum.filter(rows, &row_shown?(section, &1, words))
      end)
    end)
    |> Enum.reject(fn %{rows: rows} -> rows == [] end)
  end

  defp shown?(group, field, words) do
    visible?(text([group.title, field.key, field.label, field.help, field.env]), words)
  end

  defp row_shown?(section, row, words) do
    visible?(text([section.title, row.label, row.value, row.env]), words)
  end

  defp text(parts), do: Enum.map_join(parts, "\n", &to_string/1)
end
