defmodule ConfluencePhxMirrorWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ConfluencePhxMirrorWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User

  using do
    quote do
      # The default endpoint for testing
      @endpoint ConfluencePhxMirrorWeb.Endpoint

      use ConfluencePhxMirrorWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ConfluencePhxMirrorWeb.ConnCase
    end
  end

  setup tags do
    ConfluencePhxMirror.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  A conn with an account signed in, the way `/session` leaves one.

  The suite has no ambient administrator: `auto_admin` is off in
  `config/test.exs`, and the tests that are about that flag turn it on in one
  file of their own (`AutoAdminTest`). So a test that needs an identity says
  which one, and nothing global changes under a concurrent suite.
  """
  @spec log_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def log_in(conn, %User{} = user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  @doc "A conn with the bootstrap administrator (`admin@localhost`) signed in."
  @spec log_in_admin(Plug.Conn.t()) :: Plug.Conn.t()
  def log_in_admin(conn), do: log_in(conn, Accounts.ensure_admin!())

  @doc """
  The opening `<html>` tag of a page: the attributes the document is painted with.

  Assert against this rather than the whole page. Every emitted theme brings its own
  `[data-theme][data-scheme]` rules into the stylesheet, so a substring found anywhere
  in the page says nothing about what the reader is actually looking at.
  """
  def document_attributes(html) do
    [tag] = Regex.run(~r/<html[^>]*>/, html)
    tag
  end
end
