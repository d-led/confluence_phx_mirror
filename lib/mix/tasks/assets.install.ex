defmodule Mix.Tasks.Assets.Install do
  @shortdoc "Installs the esbuild and tailwind CLIs, both from GitHub"

  @moduledoc """
  Fetches the standalone binaries `mix assets.build` needs into `_build`.

      mix assets.install
      mix assets.install --if-missing

  esbuild comes from its own Mix task. tailwind is fetched here instead, because
  `mix tailwind.install` downloads with `:httpc`, whose default cap on response
  headers is 10 KiB, and GitHub's release redirect has answered with more than
  that since late 2026 — the install fails with
  `{:header_too_long, {:max, 10240}}` on a URL that is perfectly good. Req
  follows the redirect and reads the body without that cap.

  The version and the install path stay tailwind's own: they come from
  `Tailwind.configured_version/0` and `Tailwind.bin_path/0`, so upgrading the
  dependency keeps working. After the download the binary is asked for its
  version, so a truncated or wrong file fails here rather than in a release.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:req)

    Mix.Tasks.Esbuild.Install.run(args)
    install_tailwind(args)
  end

  defp install_tailwind(args) do
    version = Tailwind.configured_version()
    bin = Tailwind.bin_path(version)

    if "--if-missing" in args and File.exists?(bin) do
      Mix.shell().info("tailwind #{version} is already installed")
    else
      download(url_for(version, bin), bin)
      assert_version(version)
    end
  end

  # `bin_path/1` is `<prefix>/tailwind-<target>-<version><suffix>` and the
  # download is `tailwindcss-<target>`; both come from tailwind, so the target
  # is read off the path the binary is installed at.
  defp url_for(version, bin) do
    target =
      bin
      |> Path.basename()
      |> String.replace_prefix("tailwind-", "")
      |> String.replace("-#{version}", "")

    Tailwind.default_base_url()
    |> String.replace("$version", version)
    |> String.replace("$target", target)
  end

  defp download(url, bin) do
    Mix.shell().info("Downloading tailwind from #{url}")

    File.mkdir_p!(Path.dirname(bin))

    # Into a temporary name and then renamed: a build killed mid-download must
    # not leave a truncated binary where `--if-missing` would accept it. Req
    # retries a dropped connection or a 5xx with backoff, which is where a
    # flaky CDN belongs — a shell loop around the whole task cannot tell that
    # apart from a wrong URL and only delays the right answer.
    partial = bin <> ".part"

    try do
      body =
        Req.get!(url,
          decode_body: false,
          retry: :transient,
          max_retries: 3,
          receive_timeout: 60_000
        ).body

      File.write!(partial, body)
      File.chmod!(partial, 0o755)
      File.rename!(partial, bin)
    after
      File.rm(partial)
    end
  end

  defp assert_version(version) do
    case Tailwind.bin_version() do
      {:ok, ^version} ->
        :ok

      other ->
        Mix.raise("the installed tailwind does not answer v#{version} (got #{inspect(other)})")
    end
  end
end
