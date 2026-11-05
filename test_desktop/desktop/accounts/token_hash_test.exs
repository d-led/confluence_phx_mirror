defmodule ConfluencePhxMirror.Accounts.TokenHashTest do
  @moduledoc """
  What the tool's build can and cannot do with an API token.

  The deployment hashes tokens with Argon2id, and `argon2_elixir` has no Windows
  build — its Makefile has no Windows branch at all — so the desktop environment
  leaves it out. That difference has to be a value, not a crash: a build without a
  hasher stores a word that no token can match (never a weaker digest, which would
  verify), and answers `:error` for a digest it cannot compute, which is the same
  answer a wrong token gets.

  The deployment's side of this — the format, the policy, the legacy SHA-256
  upgrade — is `test/confluence_phx_mirror/accounts/token_hash_test.exs`, which
  runs where the hasher exists.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Accounts.TokenHash

  test "a token minted by a build with no hasher can never match" do
    stored = TokenHash.hash("a-token-somebody-was-shown")

    assert stored == "no-password-hasher-in-this-build"
    assert TokenHash.verify("a-token-somebody-was-shown", stored) == :error
  end

  test "a digest this build cannot compute is refused, not crashed on" do
    argon2id = "$argon2id$v=19$m=16384,t=2,p=1$c2FsdA$aGFzaA"

    assert TokenHash.verify("anything", argon2id) == :error
  end

  test "the legacy format still verifies, because it needs no hasher" do
    legacy = :crypto.hash(:sha256, "old-token") |> Base.encode16(case: :lower)

    assert TokenHash.verify("old-token", legacy) == :legacy
    assert TokenHash.verify("other-token", legacy) == :error
  end
end
