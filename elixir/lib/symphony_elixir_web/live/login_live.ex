defmodule SymphonyElixirWeb.LoginLive do
  @moduledoc """
  LiveView for user login with email/password, Remember Me, and error display.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  @impl true
  def mount(_params, session, socket) do
    error = session["login_error"]

    socket =
      socket
      |> assign(:email, "")
      |> assign(:password, "")
      |> assign(:remember_me, false)
      |> assign(:error, error)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="login-shell">
      <div class="login-card">
        <header class="login-header">
          <h1 class="login-title">Symphony Login</h1>
          <p class="login-copy">Sign in to access the operations dashboard.</p>
        </header>

        <form action="/session" method="post" class="login-form">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />

          <%= if @error do %>
            <div class="login-error" role="alert">
              <%= @error %>
            </div>
          <% end %>

          <div class="field-group">
            <label for="email" class="field-label">Email</label>
            <input
              type="email"
              id="email"
              name="email"
              value={@email}
              required
              autocomplete="email"
              class="field-input"
              placeholder="admin@symphony.local"
            />
          </div>

          <div class="field-group">
            <label for="password" class="field-label">Password</label>
            <input
              type="password"
              id="password"
              name="password"
              required
              autocomplete="current-password"
              class="field-input"
              placeholder="Enter your password"
            />
          </div>

          <div class="field-group field-group-row">
            <input type="checkbox" id="remember_me" name="remember_me" value="true" class="field-checkbox" />
            <label for="remember_me" class="field-label-inline">Remember me</label>
          </div>

          <button type="submit" class="login-button">Sign in</button>
        </form>
      </div>
    </section>
    """
  end
end
