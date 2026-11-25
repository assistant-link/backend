import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/assistant_link start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :assistant_link, AssistantLinkWeb.Endpoint, server: true
end

config :assistant_link, AssistantLinkWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# APNs token auth. Without APNS_KEY_P8, pushes are only logged. A single-line key may use `\n` for line breaks.
if config_env() != :test and System.get_env("APNS_KEY_P8") not in [nil, ""] do
  apns_env =
    case System.get_env("APNS_ENV", "production") do
      "production" -> :production
      "sandbox" -> :sandbox
      other -> raise "APNS_ENV must be production or sandbox, got: #{inspect(other)}"
    end

  config :assistant_link, AssistantLink.Push,
    key_p8: String.replace(System.fetch_env!("APNS_KEY_P8"), "\\n", "\n"),
    key_id: System.fetch_env!("APNS_KEY_ID"),
    team_id: System.fetch_env!("APNS_TEAM_ID"),
    topic: System.get_env("APNS_TOPIC", "ai.assistantlink.app"),
    env: apns_env
end

# Voice calls. Without OPENAI_API_KEY each call's WebRTC offer gets `voice_unavailable`; nothing else changes.
if config_env() != :test do
  port_range =
    case System.get_env("WEBRTC_PORT_RANGE", "") do
      "" ->
        nil

      range ->
        with [_range, first, last] <- Regex.run(~r/\A(\d+)-(\d+)\z/, range),
             {first, last} when first in 1..65_535 and last in first..65_535//1 <-
               {String.to_integer(first), String.to_integer(last)} do
          first..last//1
        else
          _invalid -> raise "WEBRTC_PORT_RANGE must look like 50000-50099, got: #{inspect(range)}"
        end
    end

  public_ip =
    case System.get_env("WEBRTC_PUBLIC_IP", "") do
      "" ->
        nil

      ip ->
        case :inet.parse_ipv4strict_address(String.to_charlist(ip)) do
          {:ok, ip} -> ip
          {:error, _reason} -> raise "WEBRTC_PUBLIC_IP must be an IPv4 address, got: #{inspect(ip)}"
        end
    end

  config :assistant_link, AssistantLink.Voice,
    listen_host: System.get_env("WEBRTC_LISTEN_HOST"),
    public_ip: public_ip,
    port_range: port_range,
    drain_timeout: if(config_env() == :prod, do: to_timeout(second: 280), else: 0)

  config :assistant_link, AssistantLink.Voice.OpenAI, api_key: System.get_env("OPENAI_API_KEY")
end

if config_env() == :dev and System.get_env("VOICE_VENDOR") == "fake" do
  config :assistant_link, AssistantLink.Voice, vendor: AssistantLink.Voice.FakeVendor
end

if config_env() == :dev do
  config :assistant_link, AssistantLinkWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Static assets, except user uploads
        ~r"priv/gettext/.*\.po$"E,
        # Gettext translations
        ~r"lib/assistant_link_web/router\.ex$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/assistant_link_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  scheme = System.get_env("PHX_SCHEME", "https")
  # The public URL agents and the app use, which differs from PORT behind a TLS-terminating proxy.
  url_port = String.to_integer(System.get_env("PHX_URL_PORT") || if(scheme == "https", do: "443", else: "80"))

  config :assistant_link, AssistantLink.Repo,
    # `true` verifies the server certificate and hostname against the system CA store. Set DATABASE_SSL=false only
    # when the database is on a private network, such as the Postgres container in deploy/docker-compose.yml.
    ssl: System.get_env("DATABASE_SSL", "true") not in ~w(false 0),
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    # Small default so the service fits within the connection limits of small hosted Postgres plans.
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :assistant_link, AssistantLinkWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :assistant_link, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :assistant_link, AssistantLinkWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :assistant_link, AssistantLinkWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  if from = System.get_env("WAKE_EMAIL_FROM") do
    config :assistant_link, AssistantLink.Links.WakeNotifier, from: from
  end

  config :assistant_link, AssistantLink.Mailer,
    # Wake emails go out through Resend. Without RESEND_API_KEY each send fails and is logged.
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")
end
