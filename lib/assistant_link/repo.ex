defmodule AssistantLink.Repo do
  use Ecto.Repo,
    otp_app: :assistant_link,
    adapter: Ecto.Adapters.Postgres
end
