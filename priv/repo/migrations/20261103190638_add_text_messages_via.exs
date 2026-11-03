defmodule AssistantLink.Repo.Migrations.AddTextMessagesVia do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:text_messages) do
      add :via, :text
    end
  end
end
