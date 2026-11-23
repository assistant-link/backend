defmodule AssistantLink.Repo.Migrations.AddAssistantsPlatform do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:assistants) do
      add :platform, :text
    end
  end
end
