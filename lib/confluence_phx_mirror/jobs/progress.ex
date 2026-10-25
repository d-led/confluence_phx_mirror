defprotocol ConfluencePhxMirror.Jobs.Progress do
  @moduledoc """
  What a job's own record says about the work, in words the jobs page can print
  without knowing what kind of work it was.

  A job is Oban's row; the record is the domain's. A sync job writes a
  `SyncRun`, and a feature that arrives later writes whatever record it needs, so
  the page asks the record instead of knowing the shapes. Three answers are
  enough for a one-line report:

    * `state/1` — the status word, and how it should read in colour;
    * `summary/1` — what has happened so far, in numbers;
    * `detail/1` — why it ended badly, or `nil`.

  A record implementing this is listed in `ConfluencePhxMirror.Jobs`' `@records`,
  which is where its job id is read from; nothing else is needed for that job's
  progress to appear beside it.
  """

  @doc """
  The record's status, and the tone it carries: `:idle` for something that has
  not begun, `:running` while it moves, `:ok`, `:warn` or `:error` for how it
  ended.
  """
  @spec state(term()) :: {String.t(), :idle | :running | :ok | :warn | :error}
  def state(record)

  @doc "What the record has done so far, as one line a reader can scan."
  @spec summary(term()) :: String.t()
  def summary(record)

  @doc "Why the record ended the way it did, when a number does not say it."
  @spec detail(term()) :: String.t() | nil
  def detail(record)

  @doc """
  Where a reader can watch this record's own log, as `{label, path}`, or `nil`
  when the record keeps none.

  Only the page's shape is fixed — a label and a link — so a record whose work
  has no log simply omits it, and the next feature brings its own.
  """
  @spec log(term()) :: {String.t(), String.t()} | nil
  def log(record)
end
