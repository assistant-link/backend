defmodule AssistantLinkWeb.API.AccountJSON do
  def show(%{account: account, credential: credential}) do
    %{account_id: account.id, credential: credential}
  end
end
