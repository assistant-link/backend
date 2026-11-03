defmodule AssistantLink.Repo.Migrations.AddLinksWebhookPingedAt do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:assistant_links) do
      add :webhook_pinged_at, :utc_datetime_usec
    end
  end
end
