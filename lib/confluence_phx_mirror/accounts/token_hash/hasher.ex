defmodule ConfluencePhxMirror.Accounts.TokenHash.Hasher do
  @moduledoc """
  The one-way digest behind an issued token, as this build can compute it.

  `argon2_elixir` is the deployment's hasher: a memory-hard Argon2id digest in PHC
  form, self-describing so its policy can be raised later. It has no Windows
  build — its Makefile has no Windows branch at all, so it links an executable
  instead of a library and names the result `.so` — and the desktop tool has to
  build for Windows. `mix.exs` therefore leaves the library out of `:desktop`, and
  `config/desktop.exs` says so by naming no hasher.

  A build without a hasher stores a word instead of a digest, deliberately not a
  weaker one: a bare SHA-256 would verify, and a token stored under the wrong
  algorithm is a secret the deployment could not check afterwards. `verify/2`
  answers `false` for every digest it cannot compute, which is the same answer a
  wrong token gets — no crash, and nothing to learn from it. The tool has one
  local reader, no sign-in and no API clients, so it never gets that far.

  The module is read from configuration rather than chosen by an `if` in this file,
  and that is deliberate: a compile-time `false` here would make every caller's
  `:current` branch provably dead in the build without the library, which is a
  warning about the build and not about the code. Resolved at run time, both
  builds infer the same types.
  """

  # Written down once, in the build that has no hasher. A word rather than a
  # hash-shaped string, so an operator who finds it in a row sees what it is
  # instead of a digest that merely never matches.
  @absent "no-password-hasher-in-this-build"

  @spec hash(String.t(), keyword()) :: String.t()
  @spec verify(String.t(), String.t()) :: boolean()

  def hash(token, policy) do
    case hasher() do
      nil -> @absent
      argon2 -> argon2.hash_pwd_salt(token, policy)
    end
  end

  def verify(token, stored) do
    case hasher() do
      nil -> false
      argon2 -> argon2.verify_pass(token, stored)
    end
  end

  # Argon2id unless the build says otherwise: `config/desktop.exs` names none,
  # because the library is not compiled there.
  defp hasher, do: Application.get_env(:confluence_phx_mirror, :password_hasher, Argon2)
end
