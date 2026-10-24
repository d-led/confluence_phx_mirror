defmodule ConfluencePhxMirrorWeb.OAuthHTML do
  @moduledoc """
  The consent page a client's authorization request renders.

  It is the one screen in the OAuth flow, and it uses the mirror's root layout
  (theme, stylesheet) without the reader shell: there is nothing to navigate to
  while a decision is pending. Written as a function rather than a template so
  the page lives next to the controller action that renders it; there is one of
  them, and a separate file would only hide it.
  """

  use ConfluencePhxMirrorWeb, :html

  def authorize(assigns) do
    ~H"""
    <main class="mx-auto flex min-h-screen max-w-xl flex-col justify-center gap-6 px-6 py-16">
      <h1 class="text-2xl font-semibold">Allow this client to read the mirror?</h1>

      <p class="text-base-content/80">
        <strong>{@client_name}</strong>
        wants to read <strong>{@mirror_name}</strong>
        as <strong>{@email}</strong>. It will see exactly what you can see and nothing else, and it
        cannot change anything: the mirror is read-only.
      </p>

      <.form for={@form} action="/oauth/authorize" method="post" class="flex gap-3">
        <input :for={{name, value} <- @request} type="hidden" name={name} value={value} />
        <button type="submit" name="decision" value="approve" class="btn btn-primary">
          Allow
        </button>
        <button type="submit" name="decision" value="deny" class="btn btn-ghost">Deny</button>
      </.form>
    </main>
    """
  end
end
