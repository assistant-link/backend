defmodule AssistantLink.Repo.Migrations.AddLinksWakeEmail do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:assistant_links) do
      add :wake_email, :text
      add :wake_email_confirmed_at, :utc_datetime_usec
    end
  end
end
