defmodule ConfluencePhxMirrorWeb.FeatureCase do
  @moduledoc """
  Reader-shaped tests: one session that walks through static pages and LiveViews
  the way a person would, without caring which is which.

  Assertions read as intent (`assert_has("h1", "Getting Started")`,
  `assert_path/2`), so a test survives a template rewrite as long as the reader
  can still get where it says.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ConfluencePhxMirrorWeb, :verified_routes

      import ConfluencePhxMirrorWeb.FeatureCase
      import PhoenixTest

      @endpoint ConfluencePhxMirrorWeb.Endpoint
    end
  end

  setup tags do
    ConfluencePhxMirror.DataCase.setup_sandbox(tags)

    {:ok,
     conn:
       Phoenix.ConnTest.build_conn()
       |> PhoenixTest.put_endpoint(ConfluencePhxMirrorWeb.Endpoint)}
  end
end
