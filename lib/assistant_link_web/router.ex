defmodule AssistantLinkWeb.Router do
  use AssistantLinkWeb, :router

  import AssistantLinkWeb.UserAuth

  alias AssistantLinkWeb.Plugs.BearerAuth

  # Generated pipeline. A CSP must allow the root layout's inline theme script and
  # LiveView's inline styles, so it is designed with the first real web pages.
  # sobelow_skip ["Config.CSP"]
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AssistantLinkWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_account_credential do
    plug BearerAuth, :account
  end

  pipeline :require_link_token do
    plug BearerAuth, :link
  end

  scope "/", AssistantLinkWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", AssistantLinkWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api/v1", AssistantLinkWeb.API do
    pipe_through :api

    post "/accounts", AccountController, :create
  end

  scope "/api/v1", AssistantLinkWeb.API do
    pipe_through [:api, :require_account_credential]

    delete "/account", AccountController, :delete
    get "/assistants", AssistantController, :index
    post "/assistants", AssistantController, :create
    post "/assistants/:assistant_id/links", LinkController, :create
    post "/links/:link_id/pairing_code", PairingCodeController, :create
  end

  scope "/api/v1", AssistantLinkWeb do
    pipe_through [:api, :require_account_credential]

    get "/connect", ConnectionController, :app
  end

  scope "/alp/v1", AssistantLinkWeb.ALP do
    pipe_through :api

    post "/pair", PairController, :create
  end

  scope "/alp/v1", AssistantLinkWeb do
    pipe_through [:api, :require_link_token]

    get "/connect", ConnectionController, :agent
  end

  ## Authentication routes
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Application.compile_env(:assistant_link, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AssistantLinkWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", AssistantLinkWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AssistantLinkWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", AssistantLinkWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AssistantLinkWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
