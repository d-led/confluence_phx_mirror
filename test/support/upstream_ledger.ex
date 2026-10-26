defmodule ConfluencePhxMirror.UpstreamLedger do
  @moduledoc """
  A source that says what a test tells it, and remembers what it was asked.

  A verify pass is judged by two things at once: what it concluded, and what it
  cost. Both are observable here — `calls/0` is the ledger, and the answers are
  whatever the test set up:

      start_supervised!({UpstreamLedger, counts: %{"ENG" => %{page: 2, blogpost: 0}},
                                        page_ids: %{"ENG" => %{page: [1, 2], blogpost: []}}})

  Everything that is not part of the question is the demo site's answer, so a
  test only writes down what it is about.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  use Agent

  alias ConfluencePhxMirror.Confluence.DemoSource

  def start_link(answers) do
    Agent.start_link(fn -> %{answers: Map.new(answers), calls: []} end, name: __MODULE__)
  end

  @doc "Changes what the source answers without restarting it."
  def configure(answers) do
    Agent.update(__MODULE__, fn state -> %{state | answers: Map.new(answers)} end)
  end

  @doc "What the source was asked, oldest first: `{:counts, key}` / `{:page_ids, key}`."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @impl true
  def counts(space_key, _opts) do
    answer({:counts, space_key}, :counts, space_key)
  end

  @impl true
  def page_ids(space_key, _opts) do
    answer({:page_ids, space_key}, :page_ids, space_key)
  end

  defp answer(call, kind, space_key) do
    configured =
      Agent.get_and_update(__MODULE__, fn state ->
        answer = get_in(state.answers, [kind, space_key]) || :unconfigured
        {answer, %{state | calls: [call | state.calls]}}
      end)

    case configured do
      :unconfigured -> {:error, {:not_configured, call}}
      {:error, _reason} = error -> error
      answer -> {:ok, answer}
    end
  end

  # The rest of the behaviour is the demo site's, so this double only answers the
  # questions it was built for.
  @impl true
  def name, do: "upstream-ledger"

  @impl true
  def kind, do: :demo

  @impl true
  def web_url, do: nil

  @impl true
  def spaces(opts), do: DemoSource.spaces(opts)

  @impl true
  def pages(space_key, opts), do: DemoSource.pages(space_key, opts)

  @impl true
  def page(confluence_id, opts), do: DemoSource.page(confluence_id, opts)

  @impl true
  def comments(confluence_id, opts), do: DemoSource.comments(confluence_id, opts)

  @impl true
  def attachments(confluence_id, opts), do: DemoSource.attachments(confluence_id, opts)

  @impl true
  def attachment_data(attachment, opts), do: DemoSource.attachment_data(attachment, opts)
end
