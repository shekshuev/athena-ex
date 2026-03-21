defmodule AthenaWeb.Router do
  use AthenaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AthenaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
  end

  pipeline :app_layout do
    plug :put_layout, html: {AthenaWeb.Layouts, :app}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AthenaWeb do
    pipe_through [:browser, :app_layout]

    get "/", PageController, :home
    get "/locale/:locale", LocaleController, :set
    post "/auth/log_in", SessionController, :create
    delete "/auth/log_out", SessionController, :delete
  end

  scope "/media", AthenaWeb do
    pipe_through :browser

    get "/*path", MediaController, :download
  end

  live_session :public,
    layout: {AthenaWeb.Layouts, :app},
    on_mount: [{AthenaWeb.Hooks.Auth, :default}] do
    scope "/auth", AthenaWeb do
      pipe_through :browser
      live "/login", AuthLive.Login, :new
    end
  end

  live_session :authenticated,
    layout: {AthenaWeb.Layouts, :dashboard},
    on_mount: [
      {AthenaWeb.Hooks.Auth, :default},
      {AthenaWeb.Hooks.Auth, :require_authenticated_user}
    ] do
    scope "/", AthenaWeb do
      pipe_through :browser
      live "/dashboard", DashboardLive.Index, :index

      live "/learn", LearnLive.Index, :index
      live "/learn/schedule", LearnLive.Schedule, :index
      live "/files", FileLive.Index, :index
      live "/community", CommunityLive.Index, :index

      scope "/studio", StudioLive do
        live "/courses", Courses, :index
        live "/courses/new", Courses, :new
        live "/courses/:id/edit", Courses, :edit

        live "/grading", Grading, :index

        live "/library", Library, :index
        live "/library/new", Library, :new
        live "/library/:id/edit", Library, :edit

        live "/courses/:id/builder", Builder, :index
      end

      live "/teaching/cohorts", TeachingLive.Cohorts, :index
      live "/teaching/instructors", TeachingLive.Instructors, :index

      scope "/admin", AdminLive do
        live "/users", Users, :index
        live "/users/new", Users, :new
        live "/users/:id/edit", Users, :edit
        live "/roles", Roles, :index
        live "/roles/new", Roles, :new
        live "/roles/:id/edit", Roles, :edit
        live "/files", Files, :index
        live "/settings", Settings, :index
      end
    end
  end

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
