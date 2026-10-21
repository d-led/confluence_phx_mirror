defmodule ConfluencePhxMirror.Accounts.ServiceTokensTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Repo

  test "a service token is stored hashed and belongs to no account" do
    {:ok, plain, token} =
      Accounts.create_service_token("confluence-webhooks", "webhook", {:system, "test"})

    assert token.user_id == nil
    assert token.scope == "webhook"
    refute token.token_hash == plain
    assert [%{id: id}] = Accounts.list_service_tokens()
    assert id == token.id
  end

  test "the token authenticates only the scope it was issued for" do
    {:ok, plain, _token} = Accounts.create_service_token("hook", "webhook", {:system, "test"})

    assert {:ok, %{scope: "webhook"}} = Accounts.authenticate_service_token(plain, "webhook")
    assert {:error, :invalid_token} = Accounts.authenticate_service_token(plain, "api")
  end

  test "a service token cannot open the reader API" do
    {:ok, plain, _token} = Accounts.create_service_token("hook", "webhook", {:system, "test"})

    assert {:error, :invalid_token} = Accounts.authenticate_api_token(plain)
  end

  test "revoking removes the token" do
    {:ok, _plain, token} = Accounts.create_service_token("hook", "webhook", {:system, "test"})

    assert :ok = Accounts.revoke_service_token(token.id, {:system, "test"})
    assert Accounts.list_service_tokens() == []

    assert Repo.exists?(
             from e in Audit.Event,
               where: e.action == "api_token.revoked" and e.entity_id == ^to_string(token.id)
           )
  end

  test "creating a service token is audited as such" do
    user = user_fixture(%{email: "admin@example.com"})
    {:ok, _plain, _token} = Accounts.create_service_token("hook", "webhook", {:user, user})

    assert Repo.exists?(
             from e in Audit.Event,
               where: e.action == "api_token.created" and e.metadata["kind"] == "service"
           )
  end
end
