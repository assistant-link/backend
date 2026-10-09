# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# The mailer uses the "Local" adapter by default, which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :assistant_link, AssistantLink.Mailer, adapter: Swoosh.Adapters.Local
config :assistant_link, AssistantLinkWeb.Connection, ping_interval: 25_000, timeout: 60_000

config :assistant_link, AssistantLinkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AssistantLinkWeb.ErrorHTML, json: AssistantLinkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AssistantLink.PubSub,
  live_view: [signing_salt: "27N7i70J"]

config :assistant_link, :scopes,
  account: [
    default: true,
    module: AssistantLink.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:account, :id],
    schema_key: :account_id,
    schema_type: :binary_id,
    schema_table: :accounts,
    test_data_fixture: AssistantLink.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :assistant_link,
  ecto_repos: [AssistantLink.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  assistant_link: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  assistant_link: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
