defmodule AssistantLink.Repo.Migrations.AddLinksWebhook do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:assistant_links) do
      add :webhook_url, :text
      add :webhook_authorization, :text
    end
  end
end
