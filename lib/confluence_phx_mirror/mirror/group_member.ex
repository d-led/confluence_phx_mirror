defmodule ConfluencePhxMirror.Mirror.GroupMember do
  @moduledoc """
  One member of a Confluence group, as the sync last saw it.

  Group membership is mirrored rather than invented: authorization decisions
  (who may read a restricted page, who may administer the mirror) replay what
  Confluence says. Members are kept even when they never signed in to the
  mirror, so the admin screen can show the whole Confluence side of the story.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_members" do
    field :group_name, :string
    field :group_key, :string
    field :subject_key, :string
    field :email, :string
    field :account_id, :string
    field :display_name, :string
    # Which read wrote this row. A membership page carries the marker of the
    # read it belongs to, and the rows still carrying an older one are gone —
    # that is how a group of half a million is replaced without loading it.
    field :seen_in, :integer

    timestamps(type: :utc_datetime)
  end

  @fields [:group_name, :group_key, :subject_key, :email, :account_id, :display_name]

  @doc false
  def changeset(member, attrs) do
    member
    |> cast(attrs, @fields)
    |> validate_required([:group_name, :group_key, :subject_key])
    |> unique_constraint([:group_key, :subject_key], name: :group_members_unique)
  end

  @doc "A group name as it is matched: Confluence ignores case."
  def key(name), do: name |> to_string() |> String.trim() |> String.downcase()

  @doc "The identity a member is matched on: their e-mail, else their account id."
  def subject_key(%{email: email}) when is_binary(email) and email != "",
    do: key(email)

  def subject_key(%{account_id: account_id}) when is_binary(account_id), do: account_id
  def subject_key(_member), do: nil

  @doc "Name to show in the UI."
  def display(%__MODULE__{} = member) do
    member.display_name || member.email || member.account_id
  end
end
