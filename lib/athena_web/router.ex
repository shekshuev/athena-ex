defmodule AthenaWeb.Router do
  use AthenaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AthenaWeb.Layouts, :root}
    plug :put_layout, html: {AthenaWeb.Layouts, :app}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AthenaWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/locale/:locale", LocaleController, :set
  end

  # Other scopes may use custom stacks.
  # scope "/api", AthenaWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:athena, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AthenaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  defp put_locale(conn, _opts) do
    case get_session(conn, :locale) do
      nil ->
        conn

      locale ->
        Gettext.put_locale(AthenaWeb.Gettext, locale)
        conn
    end
  end
end
