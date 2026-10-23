defmodule ConfluencePhxMirror.Accounts.TokenHash do
  @moduledoc """
  How an issued token is stored: one-way, self-describing, and upgradable.

  The plaintext leaves the mirror exactly once, when the token is shown. What is
  kept is an Argon2id digest in PHC string form
  (`$argon2id$v=19$m=16384,t=2,p=1$<salt>$<digest>`), which names its own
  algorithm and parameters. That is what makes the algorithm changeable: a row
  written under an older policy keeps verifying, `verify/2` answers `:legacy`
  for it, and the caller rewrites it the next time the token is presented.

  Rows written before this module existed carry a bare SHA-256 hex digest. They
  verify here and are upgraded on first use, so no client has to be re-issued a
  token because the storage changed.

  Two consequences worth knowing:

    * Argon2 salts its digests, so a token cannot be found by comparing digests.
      The `token_prefix` column is the indexed lookup key: the prefix narrows
      the table to the row that could match, and the digest decides.
    * Verification is memory-hard on purpose — about 16 MiB and a few tens of
      milliseconds at the policy below. That is paid once per request that
      presents a token, which is why the policy is configuration
      (`:token_hash_params`) rather than a constant.
  """

  # OWASP's Argon2id recommendation is 19 MiB, two passes, one lane; the library
  # takes the memory cost as a power of two, so 2^14 KiB = 16 MiB.
  @policy [t_cost: 2, m_cost: 14, parallelism: 1]

  @type verdict :: :current | :legacy | :error

  @doc "Writes `token` as a digest under the policy in force."
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token), do: Argon2.hash_pwd_salt(token, policy())

  @doc """
  Whether `token` matches `stored`.

  `:current` means it matches and the digest already meets the policy; `:legacy`
  means it matches but is behind it, so the caller should store `hash/1` of the
  same token; `:error` means it does not match.
  """
  @spec verify(String.t(), String.t() | nil) :: verdict()
  def verify(token, stored) when is_binary(token) and is_binary(stored) do
    cond do
      argon2?(stored) -> if(matches_argon2?(token, stored), do: freshness(stored), else: :error)
      legacy?(stored) -> if(legacy_matches?(token, stored), do: :legacy, else: :error)
      true -> :error
    end
  end

  def verify(_token, _stored), do: :error

  defp matches_argon2?(token, stored), do: Argon2.verify_pass(token, stored)

  defp freshness(stored) do
    if stored_params(stored) == policy_params(), do: :current, else: :legacy
  end

  defp argon2?(stored), do: String.starts_with?(stored, "$argon2")

  # The shape this module replaced: a bare lower-case SHA-256 hex digest.
  defp legacy?(stored), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, stored)

  defp legacy_matches?(token, stored) do
    digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(digest, stored)
  end

  # `m=16384,t=2,p=1` → `%{m: 16384, t: 2, p: 1}`
  defp stored_params(stored) do
    with [_, params] <- Regex.run(~r/\A\$argon2id\$v=\d+\$([^$]+)\$/, stored),
         %{} = found <-
           Regex.scan(~r/([mtp])=(\d+)/, params)
           |> Map.new(fn [_, k, v] -> {k, to_integer(v)} end) do
      found
    else
      _other -> nil
    end
  end

  defp to_integer(value), do: String.to_integer(value)

  defp policy_params do
    policy = policy()

    %{
      "m" => Integer.pow(2, Keyword.fetch!(policy, :m_cost)),
      "t" => Keyword.fetch!(policy, :t_cost),
      "p" => Keyword.fetch!(policy, :parallelism)
    }
  end

  defp policy do
    Application.get_env(:confluence_phx_mirror, :token_hash_params, @policy)
  end
end
