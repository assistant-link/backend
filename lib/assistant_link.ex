defmodule AssistantLink do
  @moduledoc """
  AssistantLink keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  use Boundary, deps: [], exports: [Accounts, Accounts.Scope, Accounts.User, Assistants, Events, Events.Event, Links]
end
