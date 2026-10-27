defmodule ConfluencePhxMirror.Accounts.UserPolicyTest do
  @moduledoc """
  What a policy decides, and what the deployment's switches imply.

  The audience of a mirror is a separate question from what an audience may see:
  a policy admits a person, `Authorization` decides which spaces that person can
  open. These tests hold that line.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.UserPolicy

  alias ConfluencePhxMirror.Accounts.UserPolicy.{
    NewUsersCanReadPublicSpaces,
    ReadersMustExistInConfluence
  }

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.TestConfig

  defp use_policy(policy) do
    TestConfig.put(:user_policy, policy)
  end

  defp in_group(email, group) do
    {:ok, _} = Mirror.replace_group_members(group, [%{email: email, display_name: "Jane"}])
  end

  describe "readers must exist in Confluence" do
    setup do
      use_policy(ReadersMustExistInConfluence)
      :ok
    end

    test "somebody the site lists in a group is admitted" do
      in_group("jane@example.com", "confluence-users")

      assert UserPolicy.allows?(%{email: "jane@example.com"}, :proxy)
    end

    test "somebody named in a space permission is admitted" do
      space = space_fixture()

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "user", subject_key: "sam@example.com"}
        ])

      assert UserPolicy.allows?(%{email: "sam@example.com"}, :proxy)
    end

    test "a stranger is refused" do
      refute UserPolicy.allows?(%{email: "stranger@example.com"}, :proxy)
    end

    test "a stranger is refused even at the sign-in door" do
      refute UserPolicy.allows?(%{email: "stranger@example.com"}, :sign_in)
    end

    test "an administrator of the mirror is admitted without the site naming them" do
      user = user_fixture(%{email: "boss@example.com", role: "admin"})

      assert UserPolicy.allows?(%{email: user.email, user: user}, :proxy)
    end

    test "a seeded administrator is admitted before they have an account" do
      TestConfig.put(:admins, ["seed@example.com"])

      assert UserPolicy.allows?(%{email: "seed@example.com"}, :proxy)
    end

    test "a group the identity provider asserts is checked against the site's membership" do
      in_group("jane@example.com", "confluence-users")

      identity = %{email: "jane@example.com", groups: ["Confluence-Users"]}

      assert UserPolicy.allows?(identity, :proxy)
    end

    test "a group the site has never shown is not evidence" do
      in_group("sam@example.com", "confluence-users")

      identity = %{email: "stranger@example.com", groups: ["engineering"]}

      refute UserPolicy.allows?(identity, :proxy)
    end

    test "a group the site lists with somebody else in it is not evidence either" do
      in_group("sam@example.com", "confluence-users")

      identity = %{email: "jane@example.com", groups: ["confluence-users"]}

      refute UserPolicy.allows?(identity, :proxy)
    end
  end

  describe "new users can read public spaces" do
    setup do
      use_policy(NewUsersCanReadPublicSpaces)
      :ok
    end

    test "anybody who arrives is admitted" do
      assert UserPolicy.allows?(%{email: "stranger@example.com"}, :proxy)
      assert UserPolicy.allows?(%{email: "stranger@example.com"}, :sign_in)
    end

    test "the mirrored space permissions still decide what they can open" do
      # Admitting a reader is not giving them the site. A space whose read
      # permissions the sync mirrored names its own readers, and this one does
      # not name the stranger.
      space = space_fixture()

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "user", subject_key: "sam@example.com"}
        ])

      user = user_fixture(%{email: "stranger@example.com"})
      scope = ConfluencePhxMirror.Accounts.Scope.for_user(user)

      assert UserPolicy.allows?(%{email: user.email, user: user}, :proxy)
      refute ConfluencePhxMirror.Authorization.can_read_space?(scope, space)
    end

    test "a space nobody restricted stays readable" do
      space = space_fixture()
      user = user_fixture(%{email: "stranger@example.com"})
      scope = ConfluencePhxMirror.Accounts.Scope.for_user(user)

      assert ConfluencePhxMirror.Authorization.can_read_space?(scope, space)
    end
  end

  describe "combining policies" do
    defmodule Never do
      @moduledoc false
      @behaviour ConfluencePhxMirror.Accounts.UserPolicy
      @impl true
      def allows?(_identity, _purpose), do: false
    end

    test "any of them is enough" do
      use_policy({:any_of, [Never, NewUsersCanReadPublicSpaces]})

      assert UserPolicy.allows?(%{email: "anyone@example.com"}, :proxy)
    end

    test "all of them must agree" do
      use_policy({:all_of, [Never, NewUsersCanReadPublicSpaces]})

      refute UserPolicy.allows?(%{email: "anyone@example.com"}, :proxy)
    end
  end

  describe "how a policy says itself" do
    defmodule ADeploymentPolicy do
      @moduledoc false
      @behaviour ConfluencePhxMirror.Accounts.UserPolicy
      @impl true
      def allows?(_identity, _purpose), do: true
    end

    test "the shipped policies read as the sentence an operator gets" do
      assert UserPolicy.describe(NewUsersCanReadPublicSpaces) ==
               "anybody may read the public spaces"

      assert UserPolicy.describe(ReadersMustExistInConfluence) ==
               "readers must exist in Confluence"
    end

    test "a combination says which policies it is made of" do
      both = [NewUsersCanReadPublicSpaces, ReadersMustExistInConfluence]

      assert UserPolicy.describe({:any_of, both}) ==
               "any of: anybody may read the public spaces or readers must exist in Confluence"

      assert UserPolicy.describe({:all_of, both}) ==
               "all of: anybody may read the public spaces and readers must exist in Confluence"
    end

    test "a policy module this project does not ship is named by its last word" do
      assert UserPolicy.describe(ADeploymentPolicy) == "ADeploymentPolicy"
    end
  end

  describe "what a deployment that names no policy keeps" do
    setup do
      TestConfig.put(:user_policy, nil)
      :ok
    end

    test "a members-only proxy and no self sign-up mean: readers must exist" do
      TestConfig.put(:proxy_auth_members_only, true)
      TestConfig.put(:self_signup, false)

      assert UserPolicy.policy(:proxy) == ReadersMustExistInConfluence
      assert UserPolicy.policy(:sign_in) == ReadersMustExistInConfluence
    end

    test "self sign-up opens the sign-in door only" do
      TestConfig.put(:proxy_auth_members_only, true)
      TestConfig.put(:self_signup, true)

      assert UserPolicy.policy(:sign_in) == NewUsersCanReadPublicSpaces
      assert UserPolicy.policy(:proxy) == ReadersMustExistInConfluence
    end

    test "a proxy that is not members-only opens the proxy door" do
      TestConfig.put(:proxy_auth_members_only, false)
      TestConfig.put(:self_signup, false)

      assert UserPolicy.policy(:proxy) == NewUsersCanReadPublicSpaces
      assert UserPolicy.policy(:sign_in) == ReadersMustExistInConfluence
    end
  end

  describe "the names a deployment may use" do
    test "the documented names map to the shipped policies" do
      assert UserPolicy.named!("new_users_can_read_public_spaces") ==
               NewUsersCanReadPublicSpaces

      assert UserPolicy.named!("allow_all") == NewUsersCanReadPublicSpaces

      assert UserPolicy.named!("readers_must_exist_in_confluence") ==
               ReadersMustExistInConfluence

      assert UserPolicy.named!("members_only") == ReadersMustExistInConfluence
    end

    test "a name nobody ships is refused rather than quietly becoming a default" do
      assert_raise ArgumentError, ~r/unknown user policy "everybody"/, fn ->
        UserPolicy.named!("everybody")
      end
    end
  end

  describe "the sign-in path" do
    test "an unknown address is admitted when the policy admits it" do
      TestConfig.put(:self_signup, false)
      use_policy(NewUsersCanReadPublicSpaces)

      assert {:ok, :sent} = Accounts.request_login("newcomer@example.com")
      assert Accounts.get_user_by_email("newcomer@example.com")
    end

    test "an unknown address is not admitted when the policy refuses it" do
      TestConfig.put(:self_signup, false)
      use_policy(ReadersMustExistInConfluence)

      assert {:error, :unknown_email} = Accounts.request_login("stranger@example.com")
      refute Accounts.get_user_by_email("stranger@example.com")
    end
  end
end
