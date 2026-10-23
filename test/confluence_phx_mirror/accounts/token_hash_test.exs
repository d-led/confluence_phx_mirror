defmodule ConfluencePhxMirror.Accounts.TokenHashTest do
  @moduledoc """
  What a stored token digest promises: it is one-way, it says which algorithm
  and parameters wrote it, and a token written under an older policy still
  verifies — as `:legacy`, so the caller can rewrite it.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Accounts.TokenHash

  @token "s3cret-token-value"

  test "a digest names its algorithm and parameters" do
    digest = TokenHash.hash(@token)

    assert digest =~ ~r/\A\$argon2id\$v=19\$m=\d+,t=\d+,p=\d+\$/
    assert TokenHash.verify(@token, digest) == :current
  end

  test "two digests of the same token differ, because the salt does" do
    refute TokenHash.hash(@token) == TokenHash.hash(@token)
    assert TokenHash.verify(@token, TokenHash.hash(@token)) == :current
  end

  test "another token does not verify" do
    assert TokenHash.verify("not-the-token", TokenHash.hash(@token)) == :error
  end

  test "a digest written under a different policy verifies, and asks to be rewritten" do
    # Anything the current policy would not produce itself.
    other = Argon2.hash_pwd_salt(@token, t_cost: 2, m_cost: 4, parallelism: 2)

    assert TokenHash.verify(@token, other) == :legacy
  end

  test "a digest from before the algorithm changed still verifies" do
    legacy = :crypto.hash(:sha256, @token) |> Base.encode16(case: :lower)

    assert TokenHash.verify(@token, legacy) == :legacy
    assert TokenHash.verify("not-the-token", legacy) == :error
  end

  test "a value that is not a digest at all is refused" do
    assert TokenHash.verify(@token, "not a hash") == :error
    assert TokenHash.verify(@token, nil) == :error
  end
end
