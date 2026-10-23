defmodule ConfluencePhxMirrorWeb.Skins.Pack do
  @moduledoc """
  A skin pack is a standalone extension: a module that contributes skins to
  the mirror's registry.

  A pack is an ordinary compiled module, so it can live in its own file, in a
  dependency, or in a release overlay. The mirror only needs it listed in
  config:

      config :confluence_phx_mirror, :skin_packs, [MyCompany.Skins]

      defmodule MyCompany.Skins do
        @behaviour ConfluencePhxMirrorWeb.Skins.Pack

        @impl true
        def skins do
          [%{name: "my-company", label: "My Company", colors: %{primary: "#0b5fff"}}]
        end
      end

  Each returned map takes the same keys as a `:skins` entry and is validated the
  same way — see `ConfluencePhxMirrorWeb.Skins`. A pack cannot shadow a built-in
  skin, and config declared skins win over a pack's skin of the same name.

  `ConfluencePhxMirrorWeb.Skins.AtlassianCloud` is the reference pack.
  """

  alias ConfluencePhxMirrorWeb.Skins

  @doc "The skins this pack contributes."
  @callback skins() :: [Skins.declaration()]
end
