defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias SymphonyElixirWeb.Plugs.{RequireAuth, RedirectIfAuthenticated}

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :authenticated do
    plug(RequireAuth)
  end

  pipeline :guest do
    plug(RedirectIfAuthenticated)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :guest])

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :authenticated])

    live("/", DashboardLive, :index)
    delete("/logout", SessionController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    delete("/api/v1/:issue_identifier", ObservabilityApiController, :stop)
    post("/api/v1/:issue_identifier/unblock", ObservabilityApiController, :unblock)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/:issue_identifier/unblock", ObservabilityApiController, :method_not_allowed)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
